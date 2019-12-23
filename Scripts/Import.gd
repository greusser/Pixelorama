extends Node

func import_brushes(path : String) -> void:
	var brushes_dir := Directory.new()
	brushes_dir.open(Global.root_directory)
	if !brushes_dir.dir_exists(path):
		brushes_dir.make_dir(path)

	var subdirectories := find_brushes(brushes_dir, path)
	for subdir_str in subdirectories:
		var subdir := Directory.new()
		find_brushes(subdir, "%s/%s" % [path, subdir_str])

	Global.brushes_from_files = Global.custom_brushes.size()

func find_brushes(brushes_dir : Directory, path : String) -> Array:
	var subdirectories := []
	var found_random_brush := 0
	path = Global.root_directory.plus_file(path)
	brushes_dir.open(path)
	brushes_dir.list_dir_begin(true)
	var file := brushes_dir.get_next()
	while file != "":
		if file.get_extension().to_upper() == "PNG":
			var image := Image.new()
			var err := image.load(path.plus_file(file))
			if err == OK:
				if "%" in file:
					if found_random_brush == 0:
						found_random_brush = Global.file_brush_container.get_child_count()
						image.convert(Image.FORMAT_RGBA8)
						Global.custom_brushes.append(image)
						Global.create_brush_button(image, Global.Brush_Types.RANDOM_FILE, file.trim_suffix(".png"))
					else:
						var brush_button = Global.file_brush_container.get_child(found_random_brush)
						brush_button.random_brushes.append(image)
				else:
					image.convert(Image.FORMAT_RGBA8)
					Global.custom_brushes.append(image)
					Global.create_brush_button(image, Global.Brush_Types.FILE, file.trim_suffix(".png"))
		elif file.get_extension() == "": # Probably a directory
			var subdir := "./%s" % [file]
			if brushes_dir.dir_exists(subdir): # If it's an actual directory
				subdirectories.append(subdir)

		file = brushes_dir.get_next()
	brushes_dir.list_dir_end()
	return subdirectories

func import_gpl(path : String) -> Palette:
	var result : Palette = null
	var file = File.new()
	if file.file_exists(path):
		file.open(path, File.READ)
		var text = file.get_as_text()
		var lines = text.split('\n')
		var line_number := 0
		var comments := ""
		for line in lines:
			# Check if valid Gimp Palette Library file
			if line_number == 0:
				if line != "GIMP Palette":
					break
				else:
					result = Palette.new()
					var name_start = path.find_last('/') + 1
					var name_end = path.find_last('.')
					if name_end > name_start:
						result.name = path.substr(name_start, name_end - name_start)

			# Comments
			if line.begins_with('#'):
				comments += line.trim_prefix('#') + '\n'
				pass
			elif line_number > 0 && line.length() >= 12:
				line = line.replace("\t", " ")
				var color_data : PoolStringArray = line.split(" ", false, 4)
				var red : float = color_data[0].to_float() / 255.0
				var green : float = color_data[1].to_float() / 255.0
				var blue : float = color_data[2].to_float() / 255.0
				var color = Color(red, green, blue)
				result.add_color(color, color_data[3])
			line_number += 1

		if result:
			result.comments = comments
		file.close()

	return result

func import_aseprite(path) -> Dictionary:
	var result = null
	var file = File.new()
	if file.file_exists(path):
		result = {}
		file.open(path, File.READ)
		
		result.header = aseprite_read_header(file)
		
		if result.header.has("error"):
			result.error = result.header.error
			return result
			
		result.frames = []
		result.canvases = []
		result.hidden_canvases = []
		result.layer_list = []
		
		# Create frames
		for i in result.header.frames:
			# Read Frame from file
			var frame = aseprite_read_frame(file)
			if frame.has("error"):
				result.error = frame.error
				return result
			result.frames.push_back(frame)
			
			# Get layer list from Frame 0
			if i == 0:
				for chunk in frame.layer_chunks:
					result.layer_list.push_back(chunk)
			
			# New Canvas with layers
			var canvas = load("res://Prefabs/Canvas.tscn").instance()
			canvas.size = Vector2(result.header.width, result.header.height).floor()
			canvas.layers.clear()
			for j in result.layer_list.size():
				var sprite := Image.new()
				sprite.create(result.header.width, result.header.height, false, Image.FORMAT_RGBA8)
		
				sprite.lock()
				var tex := ImageTexture.new()
				tex.create_from_image(sprite, 0)
		
				#Store [Image, ImageTexture, Layer Name, Visibity boolean]
				canvas.layers.append([sprite, tex, result.layer_list[j].layer_name, result.layer_list[j].visible])
			canvas.generate_layer_panels()
			result.canvases.push_back(canvas)
			
			if i > 0:
				canvas.frame = i
				result.hidden_canvases.append(canvas)
			
			# Draw Cels in Frame for each layer
			for cel_index in frame.cel_chunks.size():
				var cel = frame.cel_chunks[cel_index]
				match cel.cel_type:
					0: # (Raw Cel)
						var image = Image.new()
						image.create.create_from_data(cel.cel_width, cel.cel_height, false, Image.FORMAT_RGBA8, cel.pixel_data)
						cel.image = image
						if cel.layer_index < canvas.layers.size():
							canvas.layers[cel.layer_index][0].blend_rect(cel.image, Rect2(Vector2(0, 0), Vector2(cel.cel_width, cel.cel_height)), Vector2(cel.x_pos, cel.y_pos))
							canvas.update_texture(cel.layer_index, false)
						pass
					1: # (Linked Cel)
						pass
					2: # (Compressed Image)
						cel.uncompressed_data = cel.compressed_data.decompress(cel.cel_width * cel.cel_height * 4, File.COMPRESSION_DEFLATE )
						var image = Image.new()
						image.create_from_data(cel.cel_width, cel.cel_height, false, Image.FORMAT_RGBA8, cel.uncompressed_data)
						cel.image = image
						if cel.layer_index < canvas.layers.size():
							canvas.layers[cel.layer_index][0].blend_rect(cel.image, Rect2(Vector2(0, 0), Vector2(cel.cel_width, cel.cel_height)), Vector2(cel.x_pos, cel.y_pos))
							canvas.update_texture(cel.layer_index, false)
						pass
		file.close()
	return result

func aseprite_read_header(file : File) -> Dictionary:
	# Header (128 Bytes)
	var header = {}
	
	header.file_size = file.get_32()		# File size
	header.magic_number = file.get_16()  	# Magic number (0xA5E0)
	if header.magic_number != 0xA5E0:
		header.error = "Header read error!"
		return header
	header.frames = file.get_16()			# Frames
	header.width = file.get_16() 			# Width in pixels
	header.height = file.get_16()			# Height in pixels
	header.color_depth = file.get_16() 		# Color depth (bits per pixel)
											#	32 bpp = RGBA
											#	16 bpp = Grayscale
											#	8 bpp = Indexed
	header.flags = file.get_32()			# Flags: 1 = Layer opacity has valid value
	header.speed = file.get_16()			# Speed (milliseconds between frame, like in FLC files)
											#	DEPRECATED: You should use the frame duration field
											#	from each frame header
	file.get_32()							# Set be 0
	file.get_32()							# Set be 0
	header.transparent_index = file.get_8()	# Palette entry (index) which represent transparent color
		 									# in all non-background layers (only for Indexed sprites).
	file.get_8()							# Ignore these bytes
	file.get_8()							# Ignore these bytes
	file.get_8()							# Ignore these bytes
	header.num_colors = file.get_16()		# Number of colors (0 means 256 for old sprites)
	header.pixel_width = file.get_8()		# Pixel width (pixel ratio is "pixel width/pixel height").
	header.pixel_height = file.get_8()		# If this or pixel height field is zero, pixel ratio is 1:1
	header.grid_x = file.get_16()			# X position of the grid (SHORT)
	header.grid_y = file.get_16()			# Y position of the grid (SHORT)
	header.grid_width = file.get_16()		# Grid width (zero if there is no grid, grid size
											#	is 16x16 on Aseprite by default)
	header.grid_height = file.get_16()		# Grid height (zero if there is no grid)
	file.get_buffer(84)						# For future (set to zero)
	return header

func aseprite_read_frame(file : File) -> Dictionary:
	var frame = {}
	frame.num_bytes = file.get_32()			# Bytes in this frame
	frame.magic_number = file.get_16()		# Magic number (always 0xF1FA)
	if frame.magic_number != 0xF1FA:
		frame.error = "Frame read error!"
		return frame
	frame.old_num_chunks = file.get_16()	# Old field which specifies the number of "chunks"
			 								#	in this frame. If this value is 0xFFFF, we might
											#	have more chunks to read in this frame
											#	(so we have to use the new field)
	frame.duration = file.get_16()			# Frame duration (in milliseconds)
	file.get_16()							# For future (set to zero)
	frame.new_num_chunks = file.get_32()	# New field which specifies the number of "chunks"
											#	in this frame (if this is 0, use the old field)
	
	frame.chunks = []
	frame.color_profile_chunks = []
	frame.palette_chunks = []
	frame.layer_chunks = []
	frame.cel_chunks = []
	var chunk_count = 0
	if frame.new_num_chunks == 0 or frame.old_num_chunks < 0xFFFF:	# Use old num chunk
		chunk_count = frame.old_num_chunks
	else:	# Use new num chunk
		chunk_count = frame.new_num_chunks
		
	for i in chunk_count:
		var chunk = aseprite_read_chunk(file)
		frame.chunks.push_back(chunk)
		match chunk.type:
			"COLOR_PROFILE":
				frame.color_profile_chunks.push_back(chunk)
			"PALETTE":
				frame.palette_chunks.push_back(chunk)
			"LAYER":
				frame.layer_chunks.push_back(chunk)
			"CEL":
				frame.cel_chunks.push_back(chunk)
	return frame;

func aseprite_read_chunk(file : File) -> Dictionary:
	var chunk = {}
	chunk.size = file.get_32()
	chunk.type = file.get_16()
	chunk.data = file.get_buffer(chunk.size - 6)
	chunk = aseprite_parse_chunk(chunk)
	return chunk

func aseprite_parse_chunk(chunk : Dictionary) -> Dictionary:
	match chunk.type:
		0x0004: # Old palette chunk
			chunk.type = "OLD_PALETTE_1"
			pass
		0x0011: # Old palette chunk
			chunk.type = "OLD_PALETTE_2"
			pass
		0x2004: # Layer Chunk
			chunk.type = "LAYER"
			
			chunk.flags = (chunk.data[1] << 8) + chunk.data[0]
			chunk.visible = bool(chunk.flags & 0x01)
			chunk.editable = bool(chunk.flags & 0x02)
			chunk.lock_movement = bool(chunk.flags & 0x04)
			chunk.is_background = bool(chunk.flags & 0x08)
			chunk.prefer_linked_cells = bool(chunk.flags & 0x10)
			chunk.layer_group_collapsed = bool(chunk.flags & 0x20)
			chunk.is_reference = bool(chunk.flags * 0x40)
			
			chunk.layer_type = (chunk.data[3] << 8) + chunk.data[2] # 0 = normal, 1 = group
			chunk.is_group = chunk.layer_type == 1
			chunk.layer_child_level = (chunk.data[5] << 8) + chunk.data[4]
			
			chunk.default_layer_width = (chunk.data[7] << 8) + chunk.data[6]	# Ignored
			chunk.default_layer_height = (chunk.data[9] << 8) + chunk.data[8]	# Ignored
			
			chunk.blend_mode = (chunk.data[11] << 8) + chunk.data[10] # (always 0 for layer set)
				# Normal         = 0
				# Multiply       = 1
				# Screen         = 2
				# Overlay        = 3
				# Darken         = 4
				# Lighten        = 5
				# Color Dodge    = 6
				# Color Burn     = 7
				# Hard Light     = 8
				# Soft Light     = 9
				# Difference     = 10
				# Exclusion      = 11
				# Hue            = 12
				# Saturation     = 13
				# Color          = 14
				# Luminosity     = 15
				# Addition       = 16
				# Subtract       = 17
				# Divide         = 18
			
			chunk.opacity = chunk.data[12] # Valid only if file header flags field has bit 1 set
			# Ignore bytes 13 to 15, For future (set to zero)
			chunk.layer_name_length = (chunk.data[17] << 8) + chunk.data[16]
			chunk.layer_name = chunk.data.subarray(18, 18 + chunk.layer_name_length - 1).get_string_from_ascii()
			pass
		0x2005: # Cel Chunk
			chunk.type = "CEL"
			chunk.layer_index = (chunk.data[1] << 8) + chunk.data[0]
			chunk.x_pos = (chunk.data[3] << 8) + chunk.data[2] # SHORT
			chunk.y_pos = (chunk.data[5] << 8) + chunk.data[4] # SHORT
			chunk.opacity_level = chunk.data[6]
			chunk.cel_type = (chunk.data[8] << 8) + chunk.data[7]
			# Ignore bytes 9-15, For future (set to zero)
			match chunk.cel_type:
				0: # (Raw Cel)
					chunk.cel_width = (chunk.data[17] << 8) + chunk.data[16]
					chunk.cel_height = (chunk.data[19] << 8) + chunk.data[18]
					chunk.pixel_data = chunk.data.subarray(20, 20 + (chunk.size - 20 - 6) - 1)
					pass
				1: # (Linked Cel)
					chunk.linked_frame = (chunk.data[17] << 8) + chunk.data[16]
					pass
				2: # (Compressed Image)
					chunk.cel_width = (chunk.data[17] << 8) + chunk.data[16]
					chunk.cel_height = (chunk.data[19] << 8) + chunk.data[18]
					chunk.compressed_data = chunk.data.subarray(20, 20 + (chunk.size - 20 - 6) -1)
					pass
			pass
		0x2006: # Cel Extra Chunk
			chunk.type = "CEL_EXTRA"
			pass
		0x2007: # Color Profile Chunk
			chunk.type = "COLOR_PROFILE"
			chunk.color_type = (chunk.data[1] << 8) + chunk.data[0]
				# 0 - no color profile (as in old .aseprite files)
				# 1 - use sRGB
				# 2 - use the embedded ICC profile
			chunk.flags = (chunk.data[3] << 8) + chunk.data[2]
				# 1 - use special fixed gamma
			# Bytes 4-7 are FIXED 16:16 representing gamma, I don't want to do the math right now
			# Bytes 8-15 Reserved (set to zero)
			if chunk.color_type == 2:
				chunk.icc_length = (chunk.data[19] << 24) + (chunk.data[18] << 16) + (chunk.data[17] << 8) + chunk.data[16]
				chunk.icc_data = chunk.data.subarray(20, 20 + chunk.icc_length - 1)
			pass
		0x2016: # Mask Chunk DEPRECATED
			chunk.type = "MASK"
			pass
		0x2017: # Path Chunk (Never Used)
			chunk.type = "PATH"
			pass
		0x2018: # Tags Chunk
			chunk.type = "TAGS"
			pass
		0x2019: # Palette Chunk
			chunk.type = "PALETTE"
			chunk.palette_size = (chunk.data[3] << 24) + (chunk.data[2] << 16) + (chunk.data[1] << 8) + chunk.data[0]
			chunk.first_index_to_change = (chunk.data[7] << 24) + (chunk.data[6] << 16) + (chunk.data[5] << 8) + chunk.data[4]
			chunk.last_index_to_change = (chunk.data[11] << 24) + (chunk.data[10] << 16) + (chunk.data[9] << 8) + chunk.data[8]
			# Bytes 12-19 For future (set to zero)
			# Remaining bytes are palette color data, TBD later
			pass
		0x2020: # User Data Chunk
			chunk.type = "USER_DATA"
			pass
		0x2022: # Slice Chunk
			chunk.type = "SLICE"
			pass
	return chunk

# Called every frame. 'delta' is the elapsed time since the previous frame.
#func _process(delta):
#	pass
