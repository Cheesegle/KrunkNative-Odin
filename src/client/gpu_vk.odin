package main

// Vulkan 1.3 backend for the gpu_* interface (see gpu.odin). Built with
// -define:KRODIN_VULKAN=true (build.bat vulkan); the SPIR-V it embeds comes
// from tools/build-spirv.ps1.
//
// Conventions that keep every caller identical to the GL backend:
// - Images are rendered and stored in GL's orientation: no viewport flip, so
//   framebuffer row 0 is GL's bottom row. Texture uploads, shadow-map UVs,
//   gl_FragCoord, derivatives and readbacks all match GL, and frontFace is
//   CLOCKWISE (Vulkan measures winding with y down). Presenting to a window
//   will need one vertical flip at the end.
// - basic.vert maps GL clip z to Vulkan's 0..w, so stored depths equal GL's.
// - Binding state (program, textures, buffers, uniform blocks) behaves like GL
//   state: calls record what the next draw needs, and gpu_draw_indexed applies
//   whatever changed. Render passes start lazily at the first draw and clears
//   become load ops (or vkCmdClearAttachments inside a pass).
// - Outside gpu_frame_begin/end (map loads, readbacks) commands still work:
//   recording starts implicitly and is submitted when needed.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import glfw "vendor:glfw"
import vk "vendor:vulkan"

when KRODIN_VULKAN {

@(private = "file") SPIRV_BASIC_VERT :: #load("spirv/basic.vert.spv")
@(private = "file") SPIRV_BASIC_FRAG :: #load("spirv/basic.frag.spv")
@(private = "file") SPIRV_BATCHED_VERT :: #load("spirv/basic_batched.vert.spv")
@(private = "file") SPIRV_BATCHED_FRAG :: #load("spirv/basic_batched.frag.spv")
@(private = "file") SPIRV_SHADOW_VERT :: #load("spirv/basic_shadow.vert.spv")
@(private = "file") SPIRV_SHADOW_FRAG :: #load("spirv/basic_shadow.frag.spv")
@(private = "file") SPIRV_SHADOW_BATCHED_VERT :: #load("spirv/basic_shadow_batched.vert.spv")
@(private = "file") SPIRV_SHADOW_BATCHED_FRAG :: #load("spirv/basic_shadow_batched.frag.spv")

VK_COLOR_FORMAT :: vk.Format.R8G8B8A8_UNORM
VK_DEPTH_FORMAT :: vk.Format.D32_SFLOAT
VK_UNIFORM_RING_PER_FRAME :: 16 << 20
VK_FRAME_SETS :: 4096
VK_TEXTURE_SETS :: 8192
VK_MAX_LAYERS :: 4

// ---------------------------------------------------------------------------
// Handle tables: handle = index + 1, so 0 stays "none".

@(private = "file")
Vk_Table :: struct($T: typeid) {
	items: [dynamic]T,
	live:  [dynamic]bool,
	free:  [dynamic]u32,
}

@(private = "file")
vk_table_add :: proc(table: ^Vk_Table($T), item: T) -> u32 {
	if len(table.free) > 0 {
		index := pop(&table.free)
		table.items[index] = item
		table.live[index] = true
		return index + 1
	}
	append(&table.items, item)
	append(&table.live, true)
	return u32(len(table.items))
}

@(private = "file")
vk_table_get :: proc(table: ^Vk_Table($T), handle: u32) -> ^T {
	if handle == 0 || int(handle) > len(table.items) || !table.live[handle - 1] { return nil }
	return &table.items[handle - 1]
}

@(private = "file")
vk_table_remove :: proc(table: ^Vk_Table($T), handle: u32) {
	if handle == 0 || int(handle) > len(table.items) || !table.live[handle - 1] { return }
	table.live[handle - 1] = false
	table.items[handle - 1] = {}
	append(&table.free, handle - 1)
}

@(private = "file")
vk_table_destroy :: proc(table: ^Vk_Table($T)) {
	delete(table.items)
	delete(table.live)
	delete(table.free)
}

// ---------------------------------------------------------------------------
// Resources.

@(private = "file")
Vk_Buffer :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   int,
	mapped: [^]u8,
}

@(private = "file")
Vk_Image :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView, // every layer and mip
	format:  vk.Format,
	aspect:  vk.ImageAspectFlags,
	width:   u32,
	height:  u32,
	layers:  u32,
	mips:    u32,
	array:   bool,
	layouts: [VK_MAX_LAYERS]vk.ImageLayout,
}

@(private = "file")
Vk_Texture :: struct {
	image:            Vk_Image,
	format:           Gpu_Format,
	desc:             Gpu_Sampler_Desc,
	sampler:          vk.Sampler, // shared, from the sampler cache
	set:              vk.DescriptorSet, // set 1 with its own sampler (colour textures)
	override:         Gpu_Sampler,
	override_version: u32,
	override_set:     vk.DescriptorSet,
}

@(private = "file")
Vk_Sampler_Object :: struct {
	desc:       Gpu_Sampler_Desc,
	anisotropy: f32,
	sampler:    vk.Sampler,
	version:    u32,
}

@(private = "file")
Vk_Target :: struct {
	depth_only: bool,
	// Colour targets own their images.
	color:      Vk_Image,
	depth:      Vk_Image,
	// Depth-only targets render into one layer of a texture.
	texture:    Gpu_Texture,
	layer:      u32,
	layer_view: vk.ImageView,
	width:      u32,
	height:     u32,
}

@(private = "file")
Vk_Program :: struct {
	vert, frag: vk.ShaderModule,
	batched:    bool,
}

@(private = "file")
Vk_Input :: struct {
	layout:   Gpu_Vertex_Layout,
	vertices: Gpu_Buffer,
	indices:  Gpu_Buffer,
}

@(private = "file")
Vk_Pipeline_Key :: struct {
	program:    Gpu_Program,
	state:      Gpu_Draw_State,
	depth_only: bool,
	cull_front: bool,
}

@(private = "file")
Vk_Sampler_Key :: struct {
	desc:       Gpu_Sampler_Desc,
	anisotropy: f32,
}

@(private = "file")
Vk_Frame :: struct {
	cmd:       vk.CommandBuffer,
	fence:     vk.Fence,
	pool:      vk.DescriptorPool,
	queries:   vk.QueryPool,
	submitted: bool,
	timed:     bool,
}

@(private = "file")
Vk_State :: struct {
	ready:            bool,
	instance:         vk.Instance,
	messenger:        vk.DebugUtilsMessengerEXT,
	physical:         vk.PhysicalDevice,
	device:           vk.Device,
	queue:            vk.Queue,
	queue_family:     u32,
	props:            vk.PhysicalDeviceProperties,
	memory:           vk.PhysicalDeviceMemoryProperties,
	anisotropy:       bool,
	wireframe:        bool,
	device_name:      string,

	command_pool:     vk.CommandPool,
	upload_cmd:       vk.CommandBuffer,
	upload_fence:     vk.Fence,
	frames:           [GPU_FRAMES_IN_FLIGHT]Vk_Frame,
	slot:             int,
	recording:        bool,
	completed:        [dynamic]f64,

	set0_layout:      vk.DescriptorSetLayout,
	set1_layout:      vk.DescriptorSetLayout,
	pipeline_layout:  vk.PipelineLayout,
	texture_pool:     vk.DescriptorPool,
	pipeline_cache:   vk.PipelineCache,
	pipelines:        map[Vk_Pipeline_Key]vk.Pipeline,
	samplers:         map[Vk_Sampler_Key]vk.Sampler,
	retired_sets:     [dynamic]vk.DescriptorSet, // freed after the next idle wait

	ring:             Vk_Buffer, // per-frame uniform regions
	ring_cursor:      int,
	ring_align:       int,
	dummy_storage:    Vk_Buffer,
	readback:         Vk_Buffer,
	placeholder_array: Gpu_Texture,
	placeholder_2d:   Gpu_Texture,

	buffers:          Vk_Table(Vk_Buffer),
	textures:         Vk_Table(Vk_Texture),
	sampler_objects:  Vk_Table(Vk_Sampler_Object),
	targets:          Vk_Table(Vk_Target),
	programs:         Vk_Table(Vk_Program),
	inputs:           Vk_Table(Vk_Input),

	// What the next draw needs (GL-like binding state).
	target:           Gpu_Render_Target,
	viewport:         [2]i32,
	clear_color:      [4]f32,
	pending_color:    bool,
	pending_depth:    bool,
	program:          Gpu_Program,
	draw_state:       Gpu_Draw_State,
	input:            Gpu_Vertex_Input,
	color_texture:    Gpu_Texture,
	color_override:   Gpu_Sampler,
	shadow_texture:   Gpu_Texture,
	player_texture:   Gpu_Texture,
	objects:          Gpu_Buffer,
	pass_offset:      u32,
	draw_offset:      u32,

	// What the current command buffer has bound.
	in_pass:          bool,
	pass_depth_only:  bool,
	pass_cull_front:  bool,
	depth_pass_target: Gpu_Render_Target,
	bound_pipeline:   vk.Pipeline,
	set0:             vk.DescriptorSet,
	set0_dirty:       bool,
	bound_set0:       vk.DescriptorSet,
	bound_offsets:    [2]u32,
	bound_set1:       vk.DescriptorSet,
	bound_input:      Gpu_Vertex_Input,
	warned_no_target: bool,
}

@(private = "file")
g_vk: Vk_State

g_vk_validation_errors: int

@(private = "file")
vk_ok :: proc(result: vk.Result, what: string, loc := #caller_location) -> bool {
	if result == .SUCCESS { return true }
	fmt.eprintfln("[Vulkan] %s failed: %v (%v)", what, result, loc)
	return false
}

@(private = "file")
vk_debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, types: vk.DebugUtilsMessageTypeFlagsEXT, data: ^vk.DebugUtilsMessengerCallbackDataEXT, user: rawptr) -> b32 {
	context = runtime.default_context()
	if .ERROR in severity {
		sync.atomic_add(&g_vk_validation_errors, 1)
		fmt.eprintfln("[Vulkan validation] %s", data.pMessage)
	} else if .WARNING in severity {
		fmt.eprintfln("[Vulkan warning] %s", data.pMessage)
	}
	return false
}

// ---------------------------------------------------------------------------
// Device setup.

// Creates the instance and device (no window: rendering is offscreen).
// Validation layers load with KRODIN_VK_VALIDATION=1.
gpu_vk_init :: proc() -> bool {
	if g_vk.ready { return true }
	if !bool(glfw.VulkanSupported()) {
		fmt.eprintln("[Vulkan] No Vulkan loader or driver found")
		return false
	}
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	validation := os.get_env("KRODIN_VK_VALIDATION", context.temp_allocator) == "1"
	layers := make([dynamic]cstring, context.temp_allocator)
	if validation {
		count: u32
		vk.EnumerateInstanceLayerProperties(&count, nil)
		available := make([]vk.LayerProperties, count, context.temp_allocator)
		vk.EnumerateInstanceLayerProperties(&count, raw_data(available))
		found := false
		for &layer in available {
			if string(cstring(&layer.layerName[0])) == "VK_LAYER_KHRONOS_validation" { found = true }
		}
		if found { append(&layers, "VK_LAYER_KHRONOS_validation") } else { fmt.eprintln("[Vulkan] Validation requested but VK_LAYER_KHRONOS_validation is not installed"); validation = false }
	}
	extensions := make([dynamic]cstring, context.temp_allocator)
	for ext in glfw.GetRequiredInstanceExtensions() { append(&extensions, ext) }
	if validation { append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME) }

	app := vk.ApplicationInfo{sType = .APPLICATION_INFO, pApplicationName = "Krodin", applicationVersion = 1, pEngineName = "Krodin", engineVersion = 1, apiVersion = vk.API_VERSION_1_3}
	instance_info := vk.InstanceCreateInfo{
		sType = .INSTANCE_CREATE_INFO, pApplicationInfo = &app,
		enabledLayerCount = u32(len(layers)), ppEnabledLayerNames = raw_data(layers),
		enabledExtensionCount = u32(len(extensions)), ppEnabledExtensionNames = raw_data(extensions),
	}
	if !vk_ok(vk.CreateInstance(&instance_info, nil, &g_vk.instance), "vkCreateInstance") { return false }
	vk.load_proc_addresses_instance(g_vk.instance)
	if validation {
		messenger_info := vk.DebugUtilsMessengerCreateInfoEXT{
			sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.WARNING, .ERROR},
			messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
			pfnUserCallback = vk_debug_callback,
		}
		vk.CreateDebugUtilsMessengerEXT(g_vk.instance, &messenger_info, nil, &g_vk.messenger)
	}

	// Prefer a discrete GPU with Vulkan 1.3 and a graphics queue.
	count: u32
	vk.EnumeratePhysicalDevices(g_vk.instance, &count, nil)
	devices := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(g_vk.instance, &count, raw_data(devices))
	best_score := -1
	for device in devices {
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(device, &props)
		if props.apiVersion < vk.API_VERSION_1_3 { continue }
		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, nil)
		families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, raw_data(families))
		family := -1
		for f, i in families {
			if .GRAPHICS in f.queueFlags && f.timestampValidBits > 0 { family = i; break }
		}
		if family < 0 { continue }
		score := 0
		#partial switch props.deviceType {
		case .DISCRETE_GPU:   score = 3
		case .INTEGRATED_GPU: score = 2
		case .VIRTUAL_GPU:    score = 1
		}
		if score > best_score {
			best_score = score
			g_vk.physical, g_vk.queue_family, g_vk.props = device, u32(family), props
		}
	}
	if best_score < 0 {
		fmt.eprintln("[Vulkan] No GPU with Vulkan 1.3 and a graphics queue")
		return false
	}
	vk.GetPhysicalDeviceMemoryProperties(g_vk.physical, &g_vk.memory)
	g_vk.device_name = fmt.aprintf("%s", cstring(&g_vk.props.deviceName[0]))

	features13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES}
	features := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &features13}
	vk.GetPhysicalDeviceFeatures2(g_vk.physical, &features)
	// glslc turns `discard` into demote-to-helper-invocation for Vulkan 1.3.
	if !features13.dynamicRendering || !features13.synchronization2 || !features13.shaderDemoteToHelperInvocation {
		fmt.eprintln("[Vulkan] The GPU lacks dynamic rendering, synchronization2 or shaderDemoteToHelperInvocation")
		return false
	}
	g_vk.anisotropy = bool(features.features.samplerAnisotropy)
	g_vk.wireframe = bool(features.features.fillModeNonSolid)
	enable13 := vk.PhysicalDeviceVulkan13Features{sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, dynamicRendering = true, synchronization2 = true, shaderDemoteToHelperInvocation = true}
	enable := vk.PhysicalDeviceFeatures2{sType = .PHYSICAL_DEVICE_FEATURES_2, pNext = &enable13}
	enable.features.samplerAnisotropy = b32(g_vk.anisotropy)
	enable.features.fillModeNonSolid = b32(g_vk.wireframe)
	priority: f32 = 1
	queue_info := vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = g_vk.queue_family, queueCount = 1, pQueuePriorities = &priority}
	device_info := vk.DeviceCreateInfo{sType = .DEVICE_CREATE_INFO, pNext = &enable, queueCreateInfoCount = 1, pQueueCreateInfos = &queue_info}
	if !vk_ok(vk.CreateDevice(g_vk.physical, &device_info, nil, &g_vk.device), "vkCreateDevice") { return false }
	vk.load_proc_addresses_device(g_vk.device)
	vk.GetDeviceQueue(g_vk.device, g_vk.queue_family, 0, &g_vk.queue)

	pool_info := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = g_vk.queue_family}
	vk.CreateCommandPool(g_vk.device, &pool_info, nil, &g_vk.command_pool)
	cmds: [GPU_FRAMES_IN_FLIGHT + 1]vk.CommandBuffer
	alloc := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = g_vk.command_pool, level = .PRIMARY, commandBufferCount = len(cmds)}
	vk.AllocateCommandBuffers(g_vk.device, &alloc, &cmds[0])
	g_vk.upload_cmd = cmds[GPU_FRAMES_IN_FLIGHT]
	fence_info := vk.FenceCreateInfo{sType = .FENCE_CREATE_INFO}
	vk.CreateFence(g_vk.device, &fence_info, nil, &g_vk.upload_fence)
	frame_pool_sizes := [?]vk.DescriptorPoolSize{
		{type = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = 2 * VK_FRAME_SETS},
		{type = .STORAGE_BUFFER, descriptorCount = VK_FRAME_SETS},
		{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = 2 * VK_FRAME_SETS},
	}
	for &frame, i in g_vk.frames {
		frame.cmd = cmds[i]
		vk.CreateFence(g_vk.device, &fence_info, nil, &frame.fence)
		dp := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, maxSets = VK_FRAME_SETS, poolSizeCount = len(frame_pool_sizes), pPoolSizes = &frame_pool_sizes[0]}
		vk.CreateDescriptorPool(g_vk.device, &dp, nil, &frame.pool)
		qp := vk.QueryPoolCreateInfo{sType = .QUERY_POOL_CREATE_INFO, queryType = .TIMESTAMP, queryCount = 2}
		vk.CreateQueryPool(g_vk.device, &qp, nil, &frame.queries)
	}

	set0_bindings := [?]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		{binding = 1, descriptorType = .UNIFORM_BUFFER_DYNAMIC, descriptorCount = 1, stageFlags = {.VERTEX, .FRAGMENT}},
		{binding = 2, descriptorType = .STORAGE_BUFFER, descriptorCount = 1, stageFlags = {.VERTEX}},
		{binding = 4, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
		{binding = 5, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}},
	}
	layout_info := vk.DescriptorSetLayoutCreateInfo{sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = len(set0_bindings), pBindings = &set0_bindings[0]}
	vk.CreateDescriptorSetLayout(g_vk.device, &layout_info, nil, &g_vk.set0_layout)
	set1_binding := vk.DescriptorSetLayoutBinding{binding = 0, descriptorType = .COMBINED_IMAGE_SAMPLER, descriptorCount = 1, stageFlags = {.FRAGMENT}}
	layout_info = {sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO, bindingCount = 1, pBindings = &set1_binding}
	vk.CreateDescriptorSetLayout(g_vk.device, &layout_info, nil, &g_vk.set1_layout)
	set_layouts := [2]vk.DescriptorSetLayout{g_vk.set0_layout, g_vk.set1_layout}
	pl := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, setLayoutCount = 2, pSetLayouts = &set_layouts[0]}
	vk.CreatePipelineLayout(g_vk.device, &pl, nil, &g_vk.pipeline_layout)
	texture_pool_size := vk.DescriptorPoolSize{type = .COMBINED_IMAGE_SAMPLER, descriptorCount = VK_TEXTURE_SETS}
	tp := vk.DescriptorPoolCreateInfo{sType = .DESCRIPTOR_POOL_CREATE_INFO, flags = {.FREE_DESCRIPTOR_SET}, maxSets = VK_TEXTURE_SETS, poolSizeCount = 1, pPoolSizes = &texture_pool_size}
	vk.CreateDescriptorPool(g_vk.device, &tp, nil, &g_vk.texture_pool)
	cache_info := vk.PipelineCacheCreateInfo{sType = .PIPELINE_CACHE_CREATE_INFO}
	vk.CreatePipelineCache(g_vk.device, &cache_info, nil, &g_vk.pipeline_cache)

	g_vk.ring_align = max(int(g_vk.props.limits.minUniformBufferOffsetAlignment), 16)
	g_vk.ring = vk_buffer_make(VK_UNIFORM_RING_PER_FRAME * GPU_FRAMES_IN_FLIGHT, {.UNIFORM_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	g_vk.dummy_storage = vk_buffer_make(256, {.STORAGE_BUFFER}, {.HOST_VISIBLE, .HOST_COHERENT})
	g_vk.ready = true

	far := transmute([4]u8)f32(1)
	placeholder := Gpu_Sampler_Desc{filter = .Nearest, wrap = .Clamp, compare = true}
	g_vk.placeholder_array = gpu_texture_create({width = 1, height = 1, format = .Depth, layers = 1, sampler = placeholder}, far[:])
	g_vk.placeholder_2d = gpu_texture_create({width = 1, height = 1, format = .Depth, sampler = placeholder}, far[:])
	fmt.printfln("[Vulkan] %s, API %d.%d.%d, driver %x%s", g_vk.device_name,
		g_vk.props.apiVersion >> 22, (g_vk.props.apiVersion >> 12) & 0x3ff, g_vk.props.apiVersion & 0xfff, g_vk.props.driverVersion,
		validation ? ", validation on" : "")
	return true
}

gpu_vk_fini :: proc() {
	if !g_vk.ready { return }
	vk.DeviceWaitIdle(g_vk.device)
	device := g_vk.device
	gpu_texture_destroy(&g_vk.placeholder_array)
	gpu_texture_destroy(&g_vk.placeholder_2d)
	leaked := 0
	for live, i in g_vk.textures.live { if live { leaked += 1; h := Gpu_Texture(i + 1); gpu_texture_destroy(&h) } }
	for live, i in g_vk.targets.live { if live { leaked += 1; h := Gpu_Render_Target(i + 1); gpu_render_target_destroy(&h) } }
	for live, i in g_vk.inputs.live { if live { leaked += 1; h := Gpu_Vertex_Input(i + 1); gpu_vertex_input_destroy(&h) } }
	for live, i in g_vk.buffers.live { if live { leaked += 1; h := Gpu_Buffer(i + 1); gpu_buffer_destroy(&h) } }
	for live, i in g_vk.programs.live { if live { leaked += 1; h := Gpu_Program(i + 1); gpu_program_destroy(&h) } }
	for live, i in g_vk.sampler_objects.live { if live { leaked += 1; h := Gpu_Sampler(i + 1); gpu_sampler_destroy(&h) } }
	if leaked > 0 { fmt.eprintfln("[Vulkan] %d GPU objects were still alive at shutdown", leaked) }
	for _, pipeline in g_vk.pipelines { vk.DestroyPipeline(device, pipeline, nil) }
	for _, sampler in g_vk.samplers { vk.DestroySampler(device, sampler, nil) }
	vk_buffer_free(&g_vk.ring)
	vk_buffer_free(&g_vk.dummy_storage)
	vk_buffer_free(&g_vk.readback)
	for &frame in g_vk.frames {
		vk.DestroyFence(device, frame.fence, nil)
		vk.DestroyDescriptorPool(device, frame.pool, nil)
		vk.DestroyQueryPool(device, frame.queries, nil)
	}
	vk.DestroyFence(device, g_vk.upload_fence, nil)
	vk.DestroyCommandPool(device, g_vk.command_pool, nil)
	vk.DestroyDescriptorPool(device, g_vk.texture_pool, nil)
	vk.DestroyPipelineCache(device, g_vk.pipeline_cache, nil)
	vk.DestroyPipelineLayout(device, g_vk.pipeline_layout, nil)
	vk.DestroyDescriptorSetLayout(device, g_vk.set0_layout, nil)
	vk.DestroyDescriptorSetLayout(device, g_vk.set1_layout, nil)
	vk.DestroyDevice(device, nil)
	if g_vk.messenger != 0 { vk.DestroyDebugUtilsMessengerEXT(g_vk.instance, g_vk.messenger, nil) }
	vk.DestroyInstance(g_vk.instance, nil)
	delete(g_vk.pipelines)
	delete(g_vk.samplers)
	delete(g_vk.retired_sets)
	delete(g_vk.completed)
	delete(g_vk.device_name)
	vk_table_destroy(&g_vk.buffers)
	vk_table_destroy(&g_vk.textures)
	vk_table_destroy(&g_vk.sampler_objects)
	vk_table_destroy(&g_vk.targets)
	vk_table_destroy(&g_vk.programs)
	vk_table_destroy(&g_vk.inputs)
	g_vk = {}
}

gpu_backend_name :: proc() -> string { return "Vulkan" }
gpu_device_name :: proc() -> string { return g_vk.device_name }
gpu_context_token :: proc() -> rawptr { return rawptr(g_vk.device) }

gpu_max_anisotropy :: proc() -> f32 {
	return g_vk.anisotropy ? max(g_vk.props.limits.maxSamplerAnisotropy, 1) : 1
}

gpu_max_texture_size :: proc() -> i32 {
	return i32(g_vk.props.limits.maxImageDimension2D)
}

gpu_max_storage_buffer_size :: proc() -> i64 {
	return i64(g_vk.props.limits.maxStorageBufferRange)
}

// ---------------------------------------------------------------------------
// Memory, buffers and one-shot commands.

@(private = "file")
vk_memory_type :: proc(bits: u32, flags: vk.MemoryPropertyFlags) -> u32 {
	for i in 0 ..< g_vk.memory.memoryTypeCount {
		if bits & (1 << i) != 0 && g_vk.memory.memoryTypes[i].propertyFlags & flags == flags { return i }
	}
	return 0
}

@(private = "file")
vk_buffer_make :: proc(size: int, usage: vk.BufferUsageFlags, flags: vk.MemoryPropertyFlags) -> (b: Vk_Buffer) {
	info := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = vk.DeviceSize(max(size, 4)), usage = usage, sharingMode = .EXCLUSIVE}
	vk.CreateBuffer(g_vk.device, &info, nil, &b.buffer)
	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(g_vk.device, b.buffer, &req)
	alloc := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = vk_memory_type(req.memoryTypeBits, flags)}
	vk_ok(vk.AllocateMemory(g_vk.device, &alloc, nil, &b.memory), "vkAllocateMemory (buffer)")
	vk.BindBufferMemory(g_vk.device, b.buffer, b.memory, 0)
	b.size = size
	if .HOST_VISIBLE in flags {
		ptr: rawptr
		vk.MapMemory(g_vk.device, b.memory, 0, vk.DeviceSize(VK_WHOLE_SIZE), {}, &ptr)
		b.mapped = cast([^]u8)ptr
	}
	return
}

VK_WHOLE_SIZE :: ~u64(0)

@(private = "file")
vk_buffer_free :: proc(b: ^Vk_Buffer) {
	if b.buffer == 0 { return }
	vk.DestroyBuffer(g_vk.device, b.buffer, nil)
	vk.FreeMemory(g_vk.device, b.memory, nil)
	b^ = {}
}

@(private = "file")
vk_upload_begin :: proc() -> vk.CommandBuffer {
	vk.ResetCommandBuffer(g_vk.upload_cmd, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk.BeginCommandBuffer(g_vk.upload_cmd, &begin)
	return g_vk.upload_cmd
}

// Submits the one-shot commands and waits for them. Submitted ahead of any
// frame still being recorded, which is fine: they only touch new resources.
@(private = "file")
vk_upload_end :: proc() {
	vk.EndCommandBuffer(g_vk.upload_cmd)
	submit := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &g_vk.upload_cmd}
	vk.ResetFences(g_vk.device, 1, &g_vk.upload_fence)
	vk_ok(vk.QueueSubmit(g_vk.queue, 1, &submit, g_vk.upload_fence), "vkQueueSubmit (upload)")
	vk.WaitForFences(g_vk.device, 1, &g_vk.upload_fence, true, max(u64))
}

// Destruction waits for the GPU (simple and always safe; nothing is
// destroyed per frame on the paths that matter).
@(private = "file")
vk_idle_for_destroy :: proc() {
	if g_vk.recording { vk_submit() }
	vk.DeviceWaitIdle(g_vk.device)
	for set in g_vk.retired_sets {
		s := set
		vk.FreeDescriptorSets(g_vk.device, g_vk.texture_pool, 1, &s)
	}
	clear(&g_vk.retired_sets)
}

// Immutable: `data` is the whole contents for the buffer's lifetime.
gpu_buffer_create :: proc(kind: Gpu_Buffer_Kind, data: []u8) -> Gpu_Buffer {
	if len(data) == 0 || !g_vk.ready { return 0 }
	usage: vk.BufferUsageFlags = {.TRANSFER_DST}
	switch kind {
	case .Vertex:  usage += {.VERTEX_BUFFER}
	case .Index:   usage += {.INDEX_BUFFER}
	case .Storage: usage += {.STORAGE_BUFFER}
	}
	buffer := vk_buffer_make(len(data), usage, {.DEVICE_LOCAL})
	staging := vk_buffer_make(len(data), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer vk_buffer_free(&staging)
	mem.copy(staging.mapped, raw_data(data), len(data))
	cmd := vk_upload_begin()
	region := vk.BufferCopy{size = vk.DeviceSize(len(data))}
	vk.CmdCopyBuffer(cmd, staging.buffer, buffer.buffer, 1, &region)
	vk_upload_end()
	return Gpu_Buffer(vk_table_add(&g_vk.buffers, buffer))
}

gpu_buffer_destroy :: proc(buffer: ^Gpu_Buffer) {
	b := vk_table_get(&g_vk.buffers, u32(buffer^))
	if b == nil { buffer^ = 0; return }
	vk_idle_for_destroy()
	vk_buffer_free(b)
	if g_vk.objects == buffer^ { g_vk.objects = 0; g_vk.set0_dirty = true }
	vk_table_remove(&g_vk.buffers, u32(buffer^))
	buffer^ = 0
}

gpu_buffer_bind_storage :: proc(binding: u32, buffer: Gpu_Buffer) {
	if g_vk.objects == buffer { return }
	g_vk.objects = buffer
	g_vk.set0_dirty = true
}

gpu_vertex_input_create :: proc(layout: Gpu_Vertex_Layout, vertices, indices: Gpu_Buffer) -> Gpu_Vertex_Input {
	if vertices == 0 || indices == 0 { return 0 }
	return Gpu_Vertex_Input(vk_table_add(&g_vk.inputs, Vk_Input{layout = layout, vertices = vertices, indices = indices}))
}

gpu_vertex_input_bind :: proc(input: Gpu_Vertex_Input) {
	g_vk.input = input
}

gpu_vertex_input_destroy :: proc(input: ^Gpu_Vertex_Input) {
	if vk_table_get(&g_vk.inputs, u32(input^)) == nil { input^ = 0; return }
	if g_vk.input == input^ { g_vk.input = 0 }
	if g_vk.bound_input == input^ { g_vk.bound_input = 0 }
	vk_table_remove(&g_vk.inputs, u32(input^))
	input^ = 0
}

// ---------------------------------------------------------------------------
// Images and textures.

@(private = "file")
vk_format :: proc(format: Gpu_Format) -> vk.Format {
	switch format {
	case .RGBA8: return VK_COLOR_FORMAT
	case .R8:    return .R8_UNORM
	case .Depth: return VK_DEPTH_FORMAT
	}
	return VK_COLOR_FORMAT
}

@(private = "file")
vk_image_make :: proc(width, height, layers, mips: u32, array: bool, format: vk.Format, usage: vk.ImageUsageFlags) -> (img: Vk_Image) {
	img.format, img.width, img.height, img.layers, img.mips, img.array = format, width, height, max(layers, 1), max(mips, 1), array
	img.aspect = format == VK_DEPTH_FORMAT ? {.DEPTH} : {.COLOR}
	info := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO, imageType = .D2, format = format,
		extent = {width, height, 1}, mipLevels = img.mips, arrayLayers = img.layers,
		samples = {._1}, tiling = .OPTIMAL, usage = usage, sharingMode = .EXCLUSIVE, initialLayout = .UNDEFINED,
	}
	vk_ok(vk.CreateImage(g_vk.device, &info, nil, &img.image), "vkCreateImage")
	req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(g_vk.device, img.image, &req)
	alloc := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = vk_memory_type(req.memoryTypeBits, {.DEVICE_LOCAL})}
	vk_ok(vk.AllocateMemory(g_vk.device, &alloc, nil, &img.memory), "vkAllocateMemory (image)")
	vk.BindImageMemory(g_vk.device, img.image, img.memory, 0)
	img.view = vk_image_view(&img, 0, img.layers, array)
	return
}

@(private = "file")
vk_image_view :: proc(img: ^Vk_Image, base_layer, layer_count: u32, array: bool) -> (view: vk.ImageView) {
	info := vk.ImageViewCreateInfo{
		sType = .IMAGE_VIEW_CREATE_INFO, image = img.image,
		viewType = array ? .D2_ARRAY : .D2, format = img.format,
		subresourceRange = {aspectMask = img.aspect, baseMipLevel = 0, levelCount = img.mips, baseArrayLayer = base_layer, layerCount = layer_count},
	}
	vk.CreateImageView(g_vk.device, &info, nil, &view)
	return
}

@(private = "file")
vk_image_free :: proc(img: ^Vk_Image) {
	if img.image == 0 { return }
	vk.DestroyImageView(g_vk.device, img.view, nil)
	vk.DestroyImage(g_vk.device, img.image, nil)
	vk.FreeMemory(g_vk.device, img.memory, nil)
	img^ = {}
}

// Moves layers [first, first+count) (all mips) to `layout`. Conservative
// (all commands) synchronisation: a handful of barriers per frame.
@(private = "file")
vk_transition :: proc(cmd: vk.CommandBuffer, img: ^Vk_Image, first, count: u32, layout: vk.ImageLayout) {
	barriers: [VK_MAX_LAYERS]vk.ImageMemoryBarrier2
	n: u32
	for layer in first ..< first + count {
		barriers[n] = vk.ImageMemoryBarrier2{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.ALL_COMMANDS}, srcAccessMask = {.MEMORY_WRITE},
			dstStageMask = {.ALL_COMMANDS}, dstAccessMask = {.MEMORY_READ, .MEMORY_WRITE},
			oldLayout = img.layouts[layer], newLayout = layout,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = img.image,
			subresourceRange = {aspectMask = img.aspect, baseMipLevel = 0, levelCount = img.mips, baseArrayLayer = layer, layerCount = 1},
		}
		img.layouts[layer] = layout
		n += 1
	}
	dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = n, pImageMemoryBarriers = &barriers[0]}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

@(private = "file")
vk_sampler_get :: proc(desc: Gpu_Sampler_Desc, anisotropy: f32) -> vk.Sampler {
	key := Vk_Sampler_Key{desc, anisotropy}
	if sampler, ok := g_vk.samplers[key]; ok { return sampler }
	filter: vk.Filter = desc.filter == .Linear ? .LINEAR : .NEAREST
	wrap: vk.SamplerAddressMode = desc.wrap == .Repeat ? .REPEAT : .CLAMP_TO_EDGE
	info := vk.SamplerCreateInfo{
		sType = .SAMPLER_CREATE_INFO, magFilter = filter, minFilter = filter, mipmapMode = .NEAREST,
		addressModeU = wrap, addressModeV = wrap, addressModeW = wrap,
		// Without mip selection GL samples only the base level.
		maxLod = desc.mip_filter ? vk.LOD_CLAMP_NONE : 0,
		anisotropyEnable = b32(anisotropy > 1 && g_vk.anisotropy), maxAnisotropy = clamp(anisotropy, 1, gpu_max_anisotropy()),
		compareEnable = b32(desc.compare), compareOp = .LESS_OR_EQUAL,
		borderColor = .FLOAT_OPAQUE_WHITE,
	}
	sampler: vk.Sampler
	vk.CreateSampler(g_vk.device, &info, nil, &sampler)
	g_vk.samplers[key] = sampler
	return sampler
}

@(private = "file")
vk_texture_set :: proc(view: vk.ImageView, sampler: vk.Sampler) -> (set: vk.DescriptorSet) {
	layout := g_vk.set1_layout
	alloc := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = g_vk.texture_pool, descriptorSetCount = 1, pSetLayouts = &layout}
	if !vk_ok(vk.AllocateDescriptorSets(g_vk.device, &alloc, &set), "vkAllocateDescriptorSets (texture)") { return 0 }
	image_info := vk.DescriptorImageInfo{sampler = sampler, imageView = view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	write := vk.WriteDescriptorSet{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 0, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &image_info}
	vk.UpdateDescriptorSets(g_vk.device, 1, &write, 0, nil)
	return
}

@(private = "file")
vk_retire_set :: proc(set: vk.DescriptorSet) {
	if set != 0 { append(&g_vk.retired_sets, set) }
}

gpu_texture_create :: proc(desc: Gpu_Texture_Desc, pixels: []u8 = nil) -> Gpu_Texture {
	if desc.width <= 0 || desc.height <= 0 || desc.layers < 0 || desc.layers > VK_MAX_LAYERS || !g_vk.ready { return 0 }
	w, h := u32(desc.width), u32(desc.height)
	mips: u32 = 1
	if desc.mipmaps { mips = u32(math.floor(math.log2(f32(max(w, h))))) + 1 }
	usage: vk.ImageUsageFlags = {.SAMPLED, .TRANSFER_DST}
	if desc.mipmaps { usage += {.TRANSFER_SRC} }
	if desc.format == .Depth { usage += {.DEPTH_STENCIL_ATTACHMENT} }
	texture := Vk_Texture{format = desc.format, desc = desc.sampler}
	texture.image = vk_image_make(w, h, u32(max(desc.layers, 1)), mips, desc.layers > 0, vk_format(desc.format), usage)
	img := &texture.image

	cmd := vk_upload_begin()
	staging: Vk_Buffer
	size := int(w) * int(h) * gpu_format_bytes_per_pixel(desc.format)
	if pixels != nil && len(pixels) >= size {
		staging = vk_buffer_make(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
		mem.copy(staging.mapped, raw_data(pixels), size)
		vk_transition(cmd, img, 0, img.layers, .TRANSFER_DST_OPTIMAL)
		region := vk.BufferImageCopy{imageSubresource = {aspectMask = img.aspect, mipLevel = 0, baseArrayLayer = 0, layerCount = 1}, imageExtent = {w, h, 1}}
		vk.CmdCopyBufferToImage(cmd, staging.buffer, img.image, .TRANSFER_DST_OPTIMAL, 1, &region)
		if mips > 1 { vk_generate_mips(cmd, img) }
	}
	vk_transition(cmd, img, 0, img.layers, .SHADER_READ_ONLY_OPTIMAL)
	vk_upload_end()
	vk_buffer_free(&staging)

	texture.sampler = vk_sampler_get(desc.sampler, 1)
	if desc.format != .Depth { texture.set = vk_texture_set(img.view, texture.sampler) }
	return Gpu_Texture(vk_table_add(&g_vk.textures, texture))
}

// Level 0 is in TRANSFER_DST; builds the chain with linear blits and leaves
// every level in TRANSFER_DST (vk_transition then moves them together).
@(private = "file")
vk_generate_mips :: proc(cmd: vk.CommandBuffer, img: ^Vk_Image) {
	w, h := i32(img.width), i32(img.height)
	for level in 1 ..< img.mips {
		pre := vk.ImageMemoryBarrier2{
			sType = .IMAGE_MEMORY_BARRIER_2,
			srcStageMask = {.ALL_TRANSFER}, srcAccessMask = {.TRANSFER_WRITE},
			dstStageMask = {.ALL_TRANSFER}, dstAccessMask = {.TRANSFER_READ},
			oldLayout = .TRANSFER_DST_OPTIMAL, newLayout = .TRANSFER_SRC_OPTIMAL,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED, dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = img.image, subresourceRange = {aspectMask = {.COLOR}, baseMipLevel = level - 1, levelCount = 1, baseArrayLayer = 0, layerCount = img.layers},
		}
		dep := vk.DependencyInfo{sType = .DEPENDENCY_INFO, imageMemoryBarrierCount = 1, pImageMemoryBarriers = &pre}
		vk.CmdPipelineBarrier2(cmd, &dep)
		nw, nh := max(w / 2, 1), max(h / 2, 1)
		blit := vk.ImageBlit{
			srcSubresource = {aspectMask = {.COLOR}, mipLevel = level - 1, baseArrayLayer = 0, layerCount = img.layers},
			srcOffsets = {{0, 0, 0}, {w, h, 1}},
			dstSubresource = {aspectMask = {.COLOR}, mipLevel = level, baseArrayLayer = 0, layerCount = img.layers},
			dstOffsets = {{0, 0, 0}, {nw, nh, 1}},
		}
		vk.CmdBlitImage(cmd, img.image, .TRANSFER_SRC_OPTIMAL, img.image, .TRANSFER_DST_OPTIMAL, 1, &blit, .LINEAR)
		post := pre
		post.srcAccessMask, post.dstAccessMask = {.TRANSFER_READ}, {.TRANSFER_WRITE}
		post.oldLayout, post.newLayout = .TRANSFER_SRC_OPTIMAL, .TRANSFER_DST_OPTIMAL
		dep.pImageMemoryBarriers = &post
		vk.CmdPipelineBarrier2(cmd, &dep)
		w, h = nw, nh
	}
}

gpu_texture_update :: proc(texture: Gpu_Texture, format: Gpu_Format, x, y, width, height: i32, pixels: []u8) {
	t := vk_table_get(&g_vk.textures, u32(texture))
	size := int(width) * int(height) * gpu_format_bytes_per_pixel(format)
	if t == nil || len(pixels) < size { return }
	staging := vk_buffer_make(size, {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer vk_buffer_free(&staging)
	mem.copy(staging.mapped, raw_data(pixels), size)
	// The texture may be read by recorded frames: let them finish first.
	vk_idle_for_destroy()
	cmd := vk_upload_begin()
	vk_transition(cmd, &t.image, 0, 1, .TRANSFER_DST_OPTIMAL)
	region := vk.BufferImageCopy{imageSubresource = {aspectMask = t.image.aspect, layerCount = 1}, imageOffset = {x, y, 0}, imageExtent = {u32(width), u32(height), 1}}
	vk.CmdCopyBufferToImage(cmd, staging.buffer, t.image.image, .TRANSFER_DST_OPTIMAL, 1, &region)
	vk_transition(cmd, &t.image, 0, 1, .SHADER_READ_ONLY_OPTIMAL)
	vk_upload_end()
}

gpu_texture_set_filter :: proc(texture: Gpu_Texture, filter: Gpu_Filter) {
	t := vk_table_get(&g_vk.textures, u32(texture))
	if t == nil || t.desc.filter == filter { return }
	t.desc.filter = filter
	t.sampler = vk_sampler_get(t.desc, 1)
	if t.format != .Depth {
		vk_retire_set(t.set)
		t.set = vk_texture_set(t.image.view, t.sampler)
		vk_retire_set(t.override_set)
		t.override_set, t.override = 0, 0
	}
	g_vk.set0_dirty = true
}

gpu_texture_bind :: proc(unit: u32, texture: Gpu_Texture) {
	switch unit {
	case GPU_UNIT_COLOR: g_vk.color_texture = texture
	case GPU_UNIT_SHADOW:
		if g_vk.shadow_texture != texture { g_vk.shadow_texture = texture; g_vk.set0_dirty = true }
	case GPU_UNIT_PLAYER_SHADOW:
		if g_vk.player_texture != texture { g_vk.player_texture = texture; g_vk.set0_dirty = true }
	}
}

gpu_texture_destroy :: proc(texture: ^Gpu_Texture) {
	t := vk_table_get(&g_vk.textures, u32(texture^))
	if t == nil { texture^ = 0; return }
	if g_active_texture == texture^ { g_active_texture = 0 }
	vk_idle_for_destroy()
	if t.set != 0 { s := t.set; vk.FreeDescriptorSets(g_vk.device, g_vk.texture_pool, 1, &s) }
	if t.override_set != 0 { s := t.override_set; vk.FreeDescriptorSets(g_vk.device, g_vk.texture_pool, 1, &s) }
	vk_image_free(&t.image)
	if g_vk.color_texture == texture^ { g_vk.color_texture = 0 }
	if g_vk.shadow_texture == texture^ { g_vk.shadow_texture = 0; g_vk.set0_dirty = true }
	if g_vk.player_texture == texture^ { g_vk.player_texture = 0; g_vk.set0_dirty = true }
	g_vk.bound_set1 = 0
	vk_table_remove(&g_vk.textures, u32(texture^))
	texture^ = 0
}

gpu_sampler_create :: proc(desc: Gpu_Sampler_Desc, anisotropy: f32 = 1) -> Gpu_Sampler {
	object := Vk_Sampler_Object{desc = desc, anisotropy = anisotropy, version = 1}
	object.sampler = vk_sampler_get(desc, anisotropy)
	return Gpu_Sampler(vk_table_add(&g_vk.sampler_objects, object))
}

gpu_sampler_set_anisotropy :: proc(sampler: Gpu_Sampler, value: f32) {
	s := vk_table_get(&g_vk.sampler_objects, u32(sampler))
	if s == nil { return }
	value := clamp(value, 1, gpu_max_anisotropy())
	if s.anisotropy == value { return }
	s.anisotropy = value
	s.sampler = vk_sampler_get(s.desc, value)
	s.version += 1
}

gpu_sampler_bind :: proc(unit: u32, sampler: Gpu_Sampler) {
	if unit == GPU_UNIT_COLOR { g_vk.color_override = sampler }
}

gpu_sampler_destroy :: proc(sampler: ^Gpu_Sampler) {
	if g_vk.color_override == sampler^ { g_vk.color_override = 0 }
	vk_table_remove(&g_vk.sampler_objects, u32(sampler^))
	sampler^ = 0
}

// The colour texture's set 1, with the bound sampler override if any.
@(private = "file")
vk_color_set :: proc() -> vk.DescriptorSet {
	t := vk_table_get(&g_vk.textures, u32(g_vk.color_texture))
	if t == nil { t = vk_table_get(&g_vk.textures, u32(gpu_blank_texture())) }
	if t == nil { return 0 }
	s := vk_table_get(&g_vk.sampler_objects, u32(g_vk.color_override))
	if s == nil { return t.set }
	if t.override != g_vk.color_override || t.override_version != s.version || t.override_set == 0 {
		vk_retire_set(t.override_set)
		t.override_set = vk_texture_set(t.image.view, s.sampler)
		t.override, t.override_version = g_vk.color_override, s.version
	}
	return t.override_set
}

// ---------------------------------------------------------------------------
// Render targets.

gpu_render_target_create :: proc(width, height: i32) -> Gpu_Render_Target {
	if !g_vk.ready || width <= 0 || height <= 0 { return 0 }
	target := Vk_Target{width = u32(width), height = u32(height)}
	target.color = vk_image_make(target.width, target.height, 1, 1, false, VK_COLOR_FORMAT, {.COLOR_ATTACHMENT, .TRANSFER_SRC})
	target.depth = vk_image_make(target.width, target.height, 1, 1, false, VK_DEPTH_FORMAT, {.DEPTH_STENCIL_ATTACHMENT, .TRANSFER_SRC})
	cmd := vk_upload_begin()
	vk_transition(cmd, &target.color, 0, 1, .COLOR_ATTACHMENT_OPTIMAL)
	vk_transition(cmd, &target.depth, 0, 1, .DEPTH_ATTACHMENT_OPTIMAL)
	vk_upload_end()
	return Gpu_Render_Target(vk_table_add(&g_vk.targets, target))
}

gpu_render_target_create_depth :: proc(depth: Gpu_Texture, layer: i32 = -1) -> Gpu_Render_Target {
	t := vk_table_get(&g_vk.textures, u32(depth))
	if t == nil { return 0 }
	target := Vk_Target{depth_only = true, texture = depth, layer = u32(max(layer, 0)), width = t.image.width, height = t.image.height}
	target.layer_view = vk_image_view(&t.image, target.layer, 1, false)
	return Gpu_Render_Target(vk_table_add(&g_vk.targets, target))
}

gpu_render_target_destroy :: proc(target: ^Gpu_Render_Target) {
	t := vk_table_get(&g_vk.targets, u32(target^))
	if t == nil { target^ = 0; return }
	vk_idle_for_destroy()
	if t.depth_only {
		vk.DestroyImageView(g_vk.device, t.layer_view, nil)
	} else {
		vk_image_free(&t.color)
		vk_image_free(&t.depth)
	}
	if g_vk.target == target^ { g_vk.target = 0; g_vk.pending_color, g_vk.pending_depth = false, false }
	vk_table_remove(&g_vk.targets, u32(target^))
	target^ = 0
}

// ---------------------------------------------------------------------------
// Frames and command recording.

@(private = "file")
vk_collect :: proc(slot: int) {
	frame := &g_vk.frames[slot]
	if !frame.submitted { return }
	vk.WaitForFences(g_vk.device, 1, &frame.fence, true, max(u64))
	frame.submitted = false
	if frame.timed {
		stamps: [2]u64
		if vk.GetQueryPoolResults(g_vk.device, frame.queries, 0, 2, size_of(stamps), &stamps[0], size_of(u64), {._64, .WAIT}) == .SUCCESS {
			append(&g_vk.completed, f64(stamps[1] - stamps[0]) * f64(g_vk.props.limits.timestampPeriod) / 1e6)
		}
		frame.timed = false
	}
}

@(private = "file")
vk_begin_recording :: proc(timed: bool) {
	frame := &g_vk.frames[g_vk.slot]
	vk_collect(g_vk.slot)
	vk.ResetFences(g_vk.device, 1, &frame.fence)
	vk.ResetCommandBuffer(frame.cmd, {})
	vk.ResetDescriptorPool(g_vk.device, frame.pool, {})
	begin := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO, flags = {.ONE_TIME_SUBMIT}}
	vk.BeginCommandBuffer(frame.cmd, &begin)
	if timed {
		vk.CmdResetQueryPool(frame.cmd, frame.queries, 0, 2)
		vk.CmdWriteTimestamp2(frame.cmd, {.TOP_OF_PIPE}, frame.queries, 0)
	}
	frame.timed = timed
	g_vk.recording = true
	g_vk.ring_cursor = 0
	// A fresh command buffer has nothing bound.
	g_vk.bound_pipeline, g_vk.bound_set0, g_vk.bound_set1, g_vk.bound_input = 0, 0, 0, 0
	g_vk.set0, g_vk.set0_dirty = 0, true
	g_vk.in_pass = false
}

@(private = "file")
vk_cmd :: proc() -> vk.CommandBuffer {
	if !g_vk.recording { vk_begin_recording(false) }
	return g_vk.frames[g_vk.slot].cmd
}

@(private = "file")
vk_submit :: proc() {
	if !g_vk.recording { return }
	vk_pass_end()
	vk_flush_pending_clear()
	frame := &g_vk.frames[g_vk.slot]
	if frame.timed { vk.CmdWriteTimestamp2(frame.cmd, {.BOTTOM_OF_PIPE}, frame.queries, 1) }
	vk.EndCommandBuffer(frame.cmd)
	submit := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &frame.cmd}
	vk_ok(vk.QueueSubmit(g_vk.queue, 1, &submit, frame.fence), "vkQueueSubmit")
	frame.submitted = true
	g_vk.recording = false
	g_vk.in_pass = false
	g_vk.slot = (g_vk.slot + 1) % GPU_FRAMES_IN_FLIGHT
}

gpu_frame_wait :: proc() {
	if !g_vk.recording { vk_collect(g_vk.slot) }
}

gpu_frame_begin :: proc() {
	if g_vk.recording { vk_submit() }
	vk_begin_recording(true)
}

gpu_frame_end :: proc() {
	vk_submit()
}

gpu_frames_finish :: proc() {
	if g_vk.recording { vk_submit() }
	for i in 0 ..< GPU_FRAMES_IN_FLIGHT { vk_collect((g_vk.slot + i) % GPU_FRAMES_IN_FLIGHT) }
}

gpu_frames_take :: proc(gpu_ms: ^[dynamic]f64) {
	if gpu_ms != nil { append(gpu_ms, ..g_vk.completed[:]) }
	clear(&g_vk.completed)
}

gpu_frames_fini :: proc() {
	gpu_frames_finish()
	clear(&g_vk.completed)
}

gpu_wait_idle :: proc() {
	gpu_frames_finish()
	vk.DeviceWaitIdle(g_vk.device)
}

// ---------------------------------------------------------------------------
// Uniform data.

gpu_uniform_push :: proc(binding: u32, data: []u8) {
	if !g_vk.ready || len(data) == 0 { return }
	vk_cmd() // the ring region belongs to the frame being recorded
	offset := (g_vk.ring_cursor + g_vk.ring_align - 1) / g_vk.ring_align * g_vk.ring_align
	if offset + len(data) > VK_UNIFORM_RING_PER_FRAME {
		@(static) warned: bool
		if !warned { fmt.eprintln("[Vulkan] uniform ring full for this frame; reusing its start"); warned = true }
		offset = 0
	}
	absolute := g_vk.slot * VK_UNIFORM_RING_PER_FRAME + offset
	mem.copy(g_vk.ring.mapped[absolute:], raw_data(data), len(data))
	g_vk.ring_cursor = offset + len(data)
	if binding == GPU_BINDING_PASS { g_vk.pass_offset = u32(absolute) } else { g_vk.draw_offset = u32(absolute) }
}

gpu_uniforms_fini :: proc() {}

// ---------------------------------------------------------------------------
// Programs, pipelines and draws.

@(private = "file")
vk_shader_module :: proc(code: []u8) -> (module: vk.ShaderModule) {
	words := make([]u32, (len(code) + 3) / 4, context.temp_allocator)
	mem.copy(raw_data(words), raw_data(code), len(code))
	info := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = len(code), pCode = raw_data(words)}
	vk_ok(vk.CreateShaderModule(g_vk.device, &info, nil, &module), "vkCreateShaderModule")
	return
}

gpu_program_create_basic :: proc(batched, shadow_depth: bool) -> Gpu_Program {
	if !g_vk.ready { return 0 }
	vert, frag: []u8
	switch {
	case batched && shadow_depth: vert, frag = SPIRV_SHADOW_BATCHED_VERT, SPIRV_SHADOW_BATCHED_FRAG
	case shadow_depth:            vert, frag = SPIRV_SHADOW_VERT, SPIRV_SHADOW_FRAG
	case batched:                 vert, frag = SPIRV_BATCHED_VERT, SPIRV_BATCHED_FRAG
	case:                         vert, frag = SPIRV_BASIC_VERT, SPIRV_BASIC_FRAG
	}
	program := Vk_Program{vert = vk_shader_module(vert), frag = vk_shader_module(frag), batched = batched}
	return Gpu_Program(vk_table_add(&g_vk.programs, program))
}

gpu_program_destroy :: proc(program: ^Gpu_Program) {
	p := vk_table_get(&g_vk.programs, u32(program^))
	if p == nil { program^ = 0; return }
	vk_idle_for_destroy()
	for key, pipeline in g_vk.pipelines {
		if key.program == program^ {
			vk.DestroyPipeline(g_vk.device, pipeline, nil)
			delete_key(&g_vk.pipelines, key)
		}
	}
	vk.DestroyShaderModule(g_vk.device, p.vert, nil)
	vk.DestroyShaderModule(g_vk.device, p.frag, nil)
	if g_vk.program == program^ { g_vk.program = 0 }
	g_vk.bound_pipeline = 0
	vk_table_remove(&g_vk.programs, u32(program^))
	program^ = 0
}

gpu_program_bind :: proc(program: Gpu_Program) {
	g_vk.program = program
}

gpu_draw_state_set :: proc(state: Gpu_Draw_State) {
	g_vk.draw_state = state
}

gpu_draw_state_reset :: proc() {
	g_vk.draw_state = GPU_DRAW_STATE_DEFAULT
}

@(private = "file")
vk_pipeline_get :: proc(key: Vk_Pipeline_Key) -> vk.Pipeline {
	if pipeline, ok := g_vk.pipelines[key]; ok { return pipeline }
	p := vk_table_get(&g_vk.programs, u32(key.program))
	if p == nil { return 0 }
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = p.vert, pName = "main"},
		{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = p.frag, pName = "main"},
	}
	binding: vk.VertexInputBindingDescription
	attributes: [4]vk.VertexInputAttributeDescription
	attribute_count: u32
	if p.batched {
		binding = {binding = 0, stride = size_of(Batched_Vertex), inputRate = .VERTEX}
		attributes = {
			{location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Batched_Vertex, position))},
			{location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Batched_Vertex, tex_coord))},
			{location = 2, binding = 0, format = .R32_SFLOAT, offset = u32(offset_of(Batched_Vertex, face_idx))},
			{location = 3, binding = 0, format = .R32_SFLOAT, offset = u32(offset_of(Batched_Vertex, object_index))},
		}
		attribute_count = 4
	} else {
		binding = {binding = 0, stride = size_of(Vertex), inputRate = .VERTEX}
		attributes[0] = {location = 0, binding = 0, format = .R32G32B32_SFLOAT, offset = u32(offset_of(Vertex, position))}
		attributes[1] = {location = 1, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, tex_coord))}
		attribute_count = 2
	}
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &binding, vertexAttributeDescriptionCount = attribute_count, pVertexAttributeDescriptions = &attributes[0]}
	assembly := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST}
	viewport := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1}
	raster := vk.PipelineRasterizationStateCreateInfo{
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = key.state.wireframe && g_vk.wireframe ? .LINE : .FILL,
		cullMode = key.cull_front ? {.FRONT} : {},
		frontFace = .CLOCKWISE, // GL's counter-clockwise, measured with y down
		lineWidth = 1,
	}
	multisample := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	depth := vk.PipelineDepthStencilStateCreateInfo{sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, depthTestEnable = true, depthWriteEnable = b32(key.state.depth_write), depthCompareOp = .LESS}
	blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable = b32(key.state.blend),
		srcColorBlendFactor = .SRC_ALPHA, dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA, colorBlendOp = .ADD,
		srcAlphaBlendFactor = .SRC_ALPHA, dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA, alphaBlendOp = .ADD,
		colorWriteMask = {.R, .G, .B, .A},
	}
	blend := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = key.depth_only ? 0 : 1, pAttachments = &blend_attachment}
	dynamic_states := [2]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo{sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO, dynamicStateCount = 2, pDynamicStates = &dynamic_states[0]}
	color_format := VK_COLOR_FORMAT
	rendering := vk.PipelineRenderingCreateInfo{
		sType = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount = key.depth_only ? 0 : 1, pColorAttachmentFormats = &color_format,
		depthAttachmentFormat = VK_DEPTH_FORMAT,
	}
	info := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO, pNext = &rendering,
		stageCount = 2, pStages = &stages[0],
		pVertexInputState = &vertex_input, pInputAssemblyState = &assembly, pViewportState = &viewport,
		pRasterizationState = &raster, pMultisampleState = &multisample, pDepthStencilState = &depth,
		pColorBlendState = &blend, pDynamicState = &dynamic_info, layout = g_vk.pipeline_layout,
	}
	pipeline: vk.Pipeline
	if !vk_ok(vk.CreateGraphicsPipelines(g_vk.device, g_vk.pipeline_cache, 1, &info, nil, &pipeline), "vkCreateGraphicsPipelines") { return 0 }
	g_vk.pipelines[key] = pipeline
	return pipeline
}

@(private = "file")
vk_set_viewport :: proc(cmd: vk.CommandBuffer, width, height: u32) {
	viewport := vk.Viewport{x = 0, y = 0, width = f32(width), height = f32(height), minDepth = 0, maxDepth = 1}
	scissor := vk.Rect2D{extent = {width, height}}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)
	vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

@(private = "file")
vk_pass_end :: proc() {
	if !g_vk.in_pass { return }
	vk.CmdEndRendering(g_vk.frames[g_vk.slot].cmd)
	g_vk.in_pass = false
}

// Starts rendering to the current colour target, turning pending clears
// into load ops.
@(private = "file")
vk_pass_begin_color :: proc() -> bool {
	t := vk_table_get(&g_vk.targets, u32(g_vk.target))
	if t == nil || t.depth_only {
		if !g_vk.warned_no_target {
			fmt.eprintln("[Vulkan] Draw without a colour target (the window is not supported yet); skipped")
			g_vk.warned_no_target = true
		}
		return false
	}
	cmd := vk_cmd()
	vk_transition(cmd, &t.color, 0, 1, .COLOR_ATTACHMENT_OPTIMAL)
	vk_transition(cmd, &t.depth, 0, 1, .DEPTH_ATTACHMENT_OPTIMAL)
	color := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = t.color.view, imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = g_vk.pending_color ? .CLEAR : .LOAD, storeOp = .STORE,
	}
	color.clearValue.color.float32 = g_vk.clear_color
	depth := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = t.depth.view, imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = g_vk.pending_depth ? .CLEAR : .LOAD, storeOp = .STORE,
	}
	depth.clearValue.depthStencil = {depth = 1}
	info := vk.RenderingInfo{
		sType = .RENDERING_INFO, renderArea = {extent = {t.width, t.height}}, layerCount = 1,
		colorAttachmentCount = 1, pColorAttachments = &color, pDepthAttachment = &depth,
	}
	vk.CmdBeginRendering(cmd, &info)
	vw := g_vk.viewport.x > 0 ? u32(g_vk.viewport.x) : t.width
	vh := g_vk.viewport.y > 0 ? u32(g_vk.viewport.y) : t.height
	vk_set_viewport(cmd, min(vw, t.width), min(vh, t.height))
	g_vk.pending_color, g_vk.pending_depth = false, false
	g_vk.in_pass, g_vk.pass_depth_only, g_vk.pass_cull_front = true, false, false
	return true
}

// Clears requested on a target that is then left without drawing still happen.
@(private = "file")
vk_flush_pending_clear :: proc() {
	if !(g_vk.pending_color || g_vk.pending_depth) || g_vk.in_pass { return }
	if vk_pass_begin_color() { vk_pass_end() }
	g_vk.pending_color, g_vk.pending_depth = false, false
}

gpu_set_target :: proc(target: Gpu_Render_Target, width, height: i32) {
	if target != g_vk.target {
		if g_vk.recording {
			vk_pass_end()
			vk_flush_pending_clear()
		}
		g_vk.target = target
	}
	g_vk.viewport = {width, height}
}

gpu_set_clear_color :: proc(color: [3]f32) {
	g_vk.clear_color = {color.r, color.g, color.b, 1}
}

gpu_clear :: proc(color, depth: bool) {
	if g_vk.in_pass && !g_vk.pass_depth_only {
		attachments: [2]vk.ClearAttachment
		n: u32
		if color {
			attachments[n] = {aspectMask = {.COLOR}, colorAttachment = 0}
			attachments[n].clearValue.color.float32 = g_vk.clear_color
			n += 1
		}
		if depth {
			attachments[n] = {aspectMask = {.DEPTH}}
			attachments[n].clearValue.depthStencil = {depth = 1}
			n += 1
		}
		t := vk_table_get(&g_vk.targets, u32(g_vk.target))
		rect := vk.ClearRect{rect = {extent = {t.width, t.height}}, baseArrayLayer = 0, layerCount = 1}
		if n > 0 { vk.CmdClearAttachments(g_vk.frames[g_vk.slot].cmd, n, &attachments[0], 1, &rect) }
		return
	}
	if color { g_vk.pending_color = true }
	if depth { g_vk.pending_depth = true }
}

// Set 0 for the next draw: the uniform ring, the batch objects and the shadow
// maps (placeholders inside a depth pass, which may render into them).
@(private = "file")
vk_set0 :: proc() -> vk.DescriptorSet {
	if !g_vk.set0_dirty && g_vk.set0 != 0 { return g_vk.set0 }
	frame := &g_vk.frames[g_vk.slot]
	layout := g_vk.set0_layout
	alloc := vk.DescriptorSetAllocateInfo{sType = .DESCRIPTOR_SET_ALLOCATE_INFO, descriptorPool = frame.pool, descriptorSetCount = 1, pSetLayouts = &layout}
	set: vk.DescriptorSet
	if !vk_ok(vk.AllocateDescriptorSets(g_vk.device, &alloc, &set), "vkAllocateDescriptorSets (frame)") { return g_vk.set0 }
	pass_info := vk.DescriptorBufferInfo{buffer = g_vk.ring.buffer, offset = 0, range = size_of(Basic_Pass_Uniforms)}
	draw_info := vk.DescriptorBufferInfo{buffer = g_vk.ring.buffer, offset = 0, range = size_of(Batch_Object)}
	storage_info := vk.DescriptorBufferInfo{buffer = g_vk.dummy_storage.buffer, offset = 0, range = vk.DeviceSize(VK_WHOLE_SIZE)}
	if b := vk_table_get(&g_vk.buffers, u32(g_vk.objects)); b != nil { storage_info.buffer = b.buffer }
	shadow, player := g_vk.shadow_texture, g_vk.player_texture
	if g_vk.pass_depth_only || vk_table_get(&g_vk.textures, u32(shadow)) == nil { shadow = g_vk.placeholder_array }
	if g_vk.pass_depth_only || vk_table_get(&g_vk.textures, u32(player)) == nil { player = g_vk.placeholder_2d }
	st := vk_table_get(&g_vk.textures, u32(shadow))
	pt := vk_table_get(&g_vk.textures, u32(player))
	shadow_info := vk.DescriptorImageInfo{sampler = st.sampler, imageView = st.image.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	player_info := vk.DescriptorImageInfo{sampler = pt.sampler, imageView = pt.image.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	writes := [5]vk.WriteDescriptorSet{
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 0, descriptorCount = 1, descriptorType = .UNIFORM_BUFFER_DYNAMIC, pBufferInfo = &pass_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 1, descriptorCount = 1, descriptorType = .UNIFORM_BUFFER_DYNAMIC, pBufferInfo = &draw_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 2, descriptorCount = 1, descriptorType = .STORAGE_BUFFER, pBufferInfo = &storage_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 4, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &shadow_info},
		{sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = 5, descriptorCount = 1, descriptorType = .COMBINED_IMAGE_SAMPLER, pImageInfo = &player_info},
	}
	vk.UpdateDescriptorSets(g_vk.device, len(writes), &writes[0], 0, nil)
	g_vk.set0, g_vk.set0_dirty = set, false
	return set
}

gpu_draw_indexed :: proc(index_count: i32, first_index: u32) {
	if !g_vk.ready || index_count <= 0 { return }
	cmd := vk_cmd()
	if !g_vk.in_pass && !vk_pass_begin_color() { return }
	key := Vk_Pipeline_Key{program = g_vk.program, state = g_vk.draw_state, depth_only = g_vk.pass_depth_only, cull_front = g_vk.pass_cull_front}
	if key.depth_only { key.state.blend = false }
	pipeline := vk_pipeline_get(key)
	if pipeline == 0 { return }
	if pipeline != g_vk.bound_pipeline {
		vk.CmdBindPipeline(cmd, .GRAPHICS, pipeline)
		g_vk.bound_pipeline = pipeline
	}
	set0 := vk_set0()
	offsets := [2]u32{g_vk.pass_offset, g_vk.draw_offset}
	if set0 != g_vk.bound_set0 || offsets != g_vk.bound_offsets {
		vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g_vk.pipeline_layout, 0, 1, &set0, 2, &offsets[0])
		g_vk.bound_set0, g_vk.bound_offsets = set0, offsets
	}
	set1 := vk_color_set()
	if set1 != g_vk.bound_set1 && set1 != 0 {
		vk.CmdBindDescriptorSets(cmd, .GRAPHICS, g_vk.pipeline_layout, 1, 1, &set1, 0, nil)
		g_vk.bound_set1 = set1
	}
	if g_vk.input != g_vk.bound_input {
		input := vk_table_get(&g_vk.inputs, u32(g_vk.input))
		if input == nil { return }
		vb := vk_table_get(&g_vk.buffers, u32(input.vertices))
		ib := vk_table_get(&g_vk.buffers, u32(input.indices))
		if vb == nil || ib == nil { return }
		offset: vk.DeviceSize
		vk.CmdBindVertexBuffers(cmd, 0, 1, &vb.buffer, &offset)
		vk.CmdBindIndexBuffer(cmd, ib.buffer, 0, .UINT32)
		g_vk.bound_input = g_vk.input
	}
	vk.CmdDrawIndexed(cmd, u32(index_count), 1, first_index, 0, 0)
}

// ---------------------------------------------------------------------------
// Depth passes (shadow maps).

@(private = "file")
vk_depth_pass_finish :: proc() {
	if !g_vk.in_pass || !g_vk.pass_depth_only { return }
	vk_pass_end()
	if t := vk_table_get(&g_vk.targets, u32(g_vk.depth_pass_target)); t != nil {
		if tex := vk_table_get(&g_vk.textures, u32(t.texture)); tex != nil {
			vk_transition(g_vk.frames[g_vk.slot].cmd, &tex.image, t.layer, 1, .SHADER_READ_ONLY_OPTIMAL)
		}
	}
	g_vk.pass_depth_only = false
	g_vk.depth_pass_target = 0
	g_vk.set0_dirty = true
}

gpu_depth_pass_begin :: proc(target: Gpu_Render_Target, size: i32, cull_front: bool) {
	t := vk_table_get(&g_vk.targets, u32(target))
	if t == nil || !t.depth_only { return }
	tex := vk_table_get(&g_vk.textures, u32(t.texture))
	if tex == nil { return }
	cmd := vk_cmd()
	vk_depth_pass_finish()
	vk_pass_end()
	vk_flush_pending_clear()
	vk_transition(cmd, &tex.image, t.layer, 1, .DEPTH_ATTACHMENT_OPTIMAL)
	depth := vk.RenderingAttachmentInfo{
		sType = .RENDERING_ATTACHMENT_INFO, imageView = t.layer_view, imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR, storeOp = .STORE,
	}
	depth.clearValue.depthStencil = {depth = 1}
	info := vk.RenderingInfo{sType = .RENDERING_INFO, renderArea = {extent = {t.width, t.height}}, layerCount = 1, pDepthAttachment = &depth}
	vk.CmdBeginRendering(cmd, &info)
	vk_set_viewport(cmd, u32(size), u32(size))
	g_vk.in_pass, g_vk.pass_depth_only, g_vk.pass_cull_front = true, true, cull_front
	g_vk.depth_pass_target = target
	g_vk.draw_state = GPU_DRAW_STATE_DEFAULT
	g_vk.set0_dirty = true
}

gpu_depth_pass_end :: proc(restore: Gpu_Render_Target, viewport: [4]i32) {
	if g_vk.recording { vk_depth_pass_finish() }
	g_vk.target = restore
	g_vk.viewport = {viewport[2], viewport[3]}
}

// ---------------------------------------------------------------------------
// Readback.

@(private = "file")
vk_readback_copy :: proc(target: Gpu_Render_Target, depth: bool, width, height: i32) -> (data: [^]u8, ok: bool) {
	t := vk_table_get(&g_vk.targets, u32(target))
	if t == nil || t.depth_only { return }
	if g_vk.target == target && g_vk.recording { vk_pass_end(); vk_flush_pending_clear() }
	size := int(width) * int(height) * 4
	if g_vk.readback.size < size {
		vk_idle_for_destroy()
		vk_buffer_free(&g_vk.readback)
		g_vk.readback = vk_buffer_make(size, {.TRANSFER_DST}, {.HOST_VISIBLE, .HOST_COHERENT, .HOST_CACHED})
		if g_vk.readback.mapped == nil { g_vk.readback = vk_buffer_make(size, {.TRANSFER_DST}, {.HOST_VISIBLE, .HOST_COHERENT}) }
	}
	cmd := vk_cmd()
	vk_pass_end()
	img := depth ? &t.depth : &t.color
	attachment_layout := img.layouts[0]
	vk_transition(cmd, img, 0, 1, .TRANSFER_SRC_OPTIMAL)
	region := vk.BufferImageCopy{imageSubresource = {aspectMask = img.aspect, layerCount = 1}, imageExtent = {u32(width), u32(height), 1}}
	vk.CmdCopyImageToBuffer(cmd, img.image, .TRANSFER_SRC_OPTIMAL, g_vk.readback.buffer, 1, &region)
	vk_transition(cmd, img, 0, 1, attachment_layout == .UNDEFINED ? (depth ? .DEPTH_ATTACHMENT_OPTIMAL : .COLOR_ATTACHMENT_OPTIMAL) : attachment_layout)
	slot := g_vk.slot
	vk_submit()
	vk_collect(slot)
	return g_vk.readback.mapped, true
}

// RGB8, rows bottom-up like GL (see the orientation note at the top).
gpu_read_color_rgb :: proc(target: Gpu_Render_Target, width, height: i32, pixels: []u8) {
	if len(pixels) < int(width) * int(height) * 3 { return }
	data, ok := vk_readback_copy(target, false, width, height)
	if !ok { return }
	for i in 0 ..< int(width) * int(height) {
		pixels[i * 3 + 0] = data[i * 4 + 0]
		pixels[i * 3 + 1] = data[i * 4 + 1]
		pixels[i * 3 + 2] = data[i * 4 + 2]
	}
}

// f32 depth bits; compare only with other reads on this backend.
gpu_read_depth :: proc(target: Gpu_Render_Target, width, height: i32, depth: []u32) {
	if len(depth) < int(width) * int(height) { return }
	data, ok := vk_readback_copy(target, true, width, height)
	if !ok { return }
	mem.copy(raw_data(depth), data, int(width) * int(height) * 4)
}

} // when KRODIN_VULKAN
