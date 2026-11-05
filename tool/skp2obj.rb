# skp2obj.rb — SketchUp Ruby: dump the active model to OBJ.
#
# HISTORY: `-RubyStartup` no longer runs scripts in SketchUp 2026
# (probe-verified — flag is silently ignored). The working path is
# the installed sketchup_mcp_extension bridge: launch SketchUp with
# the .skp, then send this body's dump lambda via the MCP
# `sketchup_execute_ruby` tool. eval runs inside
# SketchupMCP::CommandRunner so `def` does NOT land — use lambdas.
#
# AXIS NOTE: our OBJ parser expects Y-up (verts stored [x,z,y]).
# SketchUp is Z-up, so emit (x, z, y) per vertex.
#
# Units: SketchUp internal lengths are inches -> *0.0254 (meters).

DST = 'C:/Users/USER/Downloads/Gerald Files/tantyahin/assets/kenney/wh_truss.obj'

$mats = {}
mat_key = lambda do |e|
  m = e.material || e.back_material
  next nil if m.nil?
  c = m.color
  key = m.name.to_s.empty? ? "m#{c.red}_#{c.green}_#{c.blue}" : m.name.gsub(/\s+/, '_')
  $mats[key] ||= [c.red / 255.0, c.green / 255.0, c.blue / 255.0]
  key
end

dump = nil
dump = lambda do |ents, tr, f, cnt|
  ents.each do |e|
    if e.is_a?(Sketchup::Face)
      mesh = e.mesh
      next if mesh.nil? || mesh.polygons.empty?
      base = cnt[0]
      mesh.points.each do |p|
        q = p.transform(tr)
        f.puts format('v %.5f %.5f %.5f', q.x.to_f * 0.0254, q.z.to_f * 0.0254, q.y.to_f * 0.0254)
      end
      k = mat_key.call(e)
      f.puts "usemtl #{k}" if k
      mesh.polygons.each do |poly|
        f.puts 'f ' + poly.map { |i| i.abs + base }.join(' ')
      end
      cnt[0] += mesh.points.length
    elsif e.is_a?(Sketchup::Group)
      dump.call(e.entities, tr * e.transformation, f, cnt)
    elsif e.is_a?(Sketchup::ComponentInstance)
      dump.call(e.definition.entities, tr * e.transformation, f, cnt)
    end
  end
end

m = Sketchup.active_model
File.open(DST, 'w') do |f|
  f.puts 'mtllib wh_truss.mtl'
  f.puts 'o wh_truss'
  dump.call(m.entities, Geom::Transformation.new, f, [0])
end
File.open(DST.sub(/\.obj$/, '.mtl'), 'w') do |f|
  $mats.each do |name, rgb|
    f.puts "newmtl #{name}"
    f.puts format('Kd %.4f %.4f %.4f', *rgb)
  end
  f.puts 'newmtl default'
  f.puts 'Kd 0.55 0.42 0.28'
end
"ok mats=#{$mats.length}"
