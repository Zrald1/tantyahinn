import bpy, sys
argv = sys.argv[sys.argv.index('--') + 1:]
src, dst = argv[0], argv[1]
ratio = float(argv[2]) if len(argv) > 2 else 1.0
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
if ratio < 1.0:
    for o in bpy.data.objects:
        if o.type == 'MESH':
            o.data = o.data.copy()  # glTF shares mesh data
            m = o.modifiers.new('dec', 'DECIMATE')
            m.ratio = ratio
            bpy.context.view_layer.objects.active = o
            bpy.ops.object.modifier_apply(modifier='dec')
bpy.ops.wm.obj_export(filepath=dst, export_materials=True)
