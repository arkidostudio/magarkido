#    Support: 453154007@qq.com
#
#    Copyright (C) 2019 周曦
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

module MagArkido

    PLUGIN_ROOT = File.dirname(File.expand_path(__FILE__))
    PATTERNS_DIR = File.join(PLUGIN_ROOT, 'Patterns')
    RESOURCE_DIR = File.join(PLUGIN_ROOT, 'Resource')

    CATEGORIES = ['Skyscraper', 'TierBuilding', 'Apartment', 'Villa'].freeze
    DEFAULT_BLOCK = [[0, 0, 0, 9, 9, 9, "BDY", 0, 0, 0, 0]].freeze

    # Keys for named-hash pattern format
    NAMED_KEYS = %w[x y z w d h mat detail face seg offset].freeze

    # Merge a raw PTNS hash (from JSON) into dest, handling both formats:
    #   Flat:   { "PatternName" => [blocks] }
    #   Nested: { "Category"    => { "PatternName" => [blocks] } }
    def self.merge_ptns(dest, ptns)
      ptns.each do |key, val|
        if val.is_a?(Hash)
          dest[key] ||= {}
          dest[key].merge!(val)
        elsif val.is_a?(Array)
          dest['Default'] ||= {}
          dest['Default'][key] = val
        end
      end
    end

    def self.initial
      require 'json'
      @mdl = Sketchup.active_model
      @mts = @mdl.materials
      @nm        = 0     # 0 = auto-choose; [[cat,key], ...] = specific patterns
      @no_detail = false
      @cb        = DEFAULT_BLOCK
      @files     = []    # [{name:, path:, clrs:, ptns:}]
      @ptn       = {}
      @clrs      = {}
      # No auto-scan of PATTERNS_DIR — manager starts empty each session.
      # Users load .mgz files explicitly via Load .mgz in the manager.
    end

    initial

    # ---------------------------------------------------------------------------
    # Safe expression resolver — replaces eval()
    # ---------------------------------------------------------------------------
    FIELD_INDICES = { 'x'=>0,'y'=>1,'z'=>2,'w'=>3,'d'=>4,'h'=>5,'seg'=>9,'offset'=>10 }.freeze

    def self.resolve(expr, t, r1, r2, r3, block_fields = nil)
      return expr unless expr.is_a?(String)

      s = expr.dup
      s.gsub!('r1', r1.to_s)
      s.gsub!('r2', r2.to_s)
      s.gsub!('r3', r3.to_s)
      s.gsub!(/lv\(t,([\d.]+)\)/) { lv(t, $1.to_f).to_s }
      if block_fields
        FIELD_INDICES.each do |name, idx|
          v = block_fields[idx]
          s.gsub!(/\b#{name}\b/, v.to_s) if v.is_a?(Numeric)
        end
      end
      raise "Unsafe expression: #{expr}" unless s =~ /\A[\d+\-*\/.()\s]+\z/
      result = eval(s) # safe: only digits and +-*/() remain
      result
    end

    # ---------------------------------------------------------------------------
    # Geometry helpers
    # ---------------------------------------------------------------------------

    def self.cube(e, p, w, d, h)
      p1 = p + [w, 0, 0]
      p2 = p + [0, d, 0]
      p3 = p + [w, d, 0]
      c  = e.add_group
      f  = c.entities.add_face(p, p2, p3, p1)
      f.pushpull(-h, true)
      f.reverse!
      c
    end

    def self.dv1(g, f, n, s = 0)
      fs, ps = [], []
      g.entities.each { |e| fs << e if e.is_a?(Sketchup::Face) }
      return if fs.empty? || fs[f].nil?
      vs = fs[f].vertices
      vs.each { |v| ps << v.position }
      eg = vs[0].edges - fs[f].edges
      return if eg.empty?
      vt = fs[f].normal.reverse
      vt.length = eg[0].length / n
      (1...n - s).each do |i|
        ps.map! { |p| p += vt }
        g.entities.add_edges(ps[0], ps[1], ps[2], ps[3], ps[0]) if i > s
      end
    end

    def self.dv2(g, f, n, s = 0)
      fs, ps = [], []
      g.entities.each { |e| fs << e if e.is_a?(Sketchup::Face) }
      return if fs.empty? || fs[f].nil?
      fs[f].edges.each do |e|
        p, vt = e.start.position, e.line[1]
        vt.length = e.length / n
        (1...n - s).each { |i| p += vt; ps << p if i > s }
      end
      perp = fs[f].vertices[0].edges - fs[f].edges
      return if perp.empty?
      vt = fs[f].normal.reverse
      vt.length = perp[0].length
      li = ps.map { |p| [p, p + vt] }
      li.each { |l| g.entities.add_edges l }
    end

    def self.lv(t, m)
      (t.bounds.depth / m * 0.0254).round(0)
    end

    def self.normalise_block(b)
      return b if b.is_a?(Array)
      NAMED_KEYS.map { |k| b[k] }
    end

    # ---------------------------------------------------------------------------
    # Create building geometry inside target group/component
    # ---------------------------------------------------------------------------
    def self.create(t, pattern_data, detail = 0, ptn_name = nil)
      case t
      when Sketchup::Group             then e = t.entities.add_group
      when Sketchup::ComponentInstance then e = t.definition.entities.add_group
      else return
      end

      # Capture target dimensions in LOCAL space so t.transformation (including any
      # scale from the Scale tool) is not double-applied on a subsequent Transform All.
      # ComponentInstances: definition.bounds is already local — correct.
      # Groups: t.bounds is world-space and includes the Scale-tool scale, so we
      # compute local bounds from the existing entities instead. Empty group falls
      # back to t.bounds (no transformation scale to worry about in that case).
      if t.is_a?(Sketchup::ComponentInstance)
        bb = t.definition.bounds
        target_w = bb.width; target_h = bb.height; target_d = bb.depth
      else
        local_bb = Geom::BoundingBox.new
        t.entities.each { |ent| next if ent == e; local_bb.add(ent.bounds) rescue nil }
        if local_bb.valid?
          target_w = local_bb.width; target_h = local_bb.height; target_d = local_bb.depth
        else
          bb = t.bounds
          target_w = bb.width; target_h = bb.height; target_d = bb.depth
        end
      end

      r1, r2, r3 = rand(2), rand(2), rand(2)

      blocks = pattern_data.map { |b| normalise_block(b).dup }

      blocks.each do |n|
        (0..10).each do |i|
          next if i == 6
          n[i] = resolve(n[i], t, r1, r2, r3) if n[i].is_a?(String)
        end
        (0..10).each do |i|
          next if i == 6
          n[i] = resolve(n[i], t, r1, r2, r3, n) if n[i].is_a?(String)
        end
      end

      blocks.each_with_index do |n, i|
        next if [n[3], n[4], n[5]].any? { |v| !v.is_a?(Numeric) || v <= 0 }
        c = cube(e.entities, Geom::Point3d.new(n[0], n[1], n[2]), n[3], n[4], n[5])
        c.name = "Block #{i + 1}"
        c.material = n[6]
        unless @no_detail || (detail == 0 && n[7] == 0)
          dv1(c, n[8], n[9], n[10]) if n[7] == 1
          dv2(c, n[8], n[9], n[10]) if n[7] == 2
        end
      end

      e.transform! Geom::Transformation.rotation(e.bounds.center, Z_AXIS, 90.degrees * rand(4)) if detail == 0
      e.transform! Geom::Transformation.new(e.bounds.min).inverse

      s = Geom::Transformation.scaling(
        target_w / e.bounds.width,
        target_h / e.bounds.height,
        target_d / e.bounds.depth
      )
      e.transform! s

      ents = t.is_a?(Sketchup::ComponentInstance) ? t.definition.entities : t.entities
      ents.each { |x| x.erase! if x != e }
      e.explode

      t.name = ptn_name if ptn_name && !ptn_name.empty?
    end

    # ---------------------------------------------------------------------------
    # Auto-select a pattern
    # ---------------------------------------------------------------------------
    def self.choose(t)
      if @nm.is_a?(Array) && !@nm.empty?
        pair = @nm[rand(@nm.size)]
        data = ((@ptn[pair[0]] || {})[pair[1]]) || @cb
        return { data: data, cat: pair[0].to_s, name: pair[1].to_s }
      end
      all_pairs = @ptn.flat_map { |cat, ptns| ptns.map { |k, v| [cat, k, v] } }.select { |_, _, v| v.is_a?(Array) }
      if all_pairs.empty?
        { data: @cb, cat: '', name: '' }
      else
        cat, name, data = all_pairs[rand(all_pairs.size)]
        { data: data, cat: cat.to_s, name: name.to_s }
      end
    end

    # ---------------------------------------------------------------------------
    # Absorb
    # ---------------------------------------------------------------------------
    def self.resolve_mat_key(entity)
      mat = entity.material
      return 'BDY' unless mat
      name = mat.name.upcase
      @clrs.key?(name) ? name : 'BDY'
    end

    def self.to_model_units(inches)
      factor = case @mdl.options['UnitsOptions']['LengthUnit']
               when 1 then 1.0 / 12.0
               when 2 then 25.4
               when 3 then 2.54
               when 4 then 0.0254
               else 1.0
               end
      (inches * factor).round(3)
    end

    def self.absorb_to_editor
      sel = @mdl.selection.first
      unless sel.is_a?(Sketchup::Group) || sel.is_a?(Sketchup::ComponentInstance)
        UI.messagebox('Select a group or component containing sub-groups to absorb.')
        return
      end

      entities = sel.is_a?(Sketchup::Group) ? sel.entities : sel.definition.entities
      children = entities.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }

      if children.empty?
        UI.messagebox("No sub-groups found inside the selection.\nModel each block as a separate nested group inside a parent group.")
        return
      end

      min_x = children.map { |c| c.bounds.min.x }.min
      min_y = children.map { |c| c.bounds.min.y }.min
      min_z = children.map { |c| c.bounds.min.z }.min

      blocks = children.map do |c|
        b = c.bounds
        {
          'x' => to_model_units(b.min.x - min_x),
          'y' => to_model_units(b.min.y - min_y),
          'z' => to_model_units(b.min.z - min_z),
          'w' => to_model_units(b.width),
          'd' => to_model_units(b.height),
          'h' => to_model_units(b.depth),
          'mat' => resolve_mat_key(c),
          'detail' => 0, 'face' => 0, 'seg' => 6, 'offset' => 0
        }
      end

      entity_name = (sel.respond_to?(:name) && !sel.name.to_s.empty?) ? sel.name : ''
      @mgr.execute_script("receiveAbsorb(#{JSON.generate(blocks)}, #{JSON.generate(entity_name)})")
    end

    # ---------------------------------------------------------------------------
    # Main transform command
    # ---------------------------------------------------------------------------
    def self.transform_all(detail, reset = false)
      sel = @mdl.selection
      return if sel.empty?
      if !reset && @nm == 0 && @ptn.empty?
        UI.messagebox("No patterns loaded.\nOpen the Pattern Manager, load a .mgz file, then select the patterns you want.")
        return
      end

      total   = sel.select { |t| t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance) }.size
      done    = 0
      changed = []

      @mdl.start_operation('MagArkido Transform', true)
      begin
        sel.each do |t|
          next unless t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance)
          ptn = reset ? { data: @cb, cat: '', name: '' } : choose(t)
          unless t.is_a?(Sketchup::ComponentInstance) && changed.include?(t.definition)
            ptn_label = [ptn[:name], ptn[:cat]].reject(&:empty?).join('-')
            create(t, ptn[:data], detail, ptn_label)
          end
          changed << t.definition if t.is_a?(Sketchup::ComponentInstance)
          done += 1
          Sketchup.status_text = "MagArkido: Processing #{done} of #{total}..."
        end
      rescue => e
        puts "MagArkido error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        initial
      end
      @mdl.commit_operation
      Sketchup.status_text = "MagArkido: Done — #{done} object#{done == 1 ? '' : 's'} transformed."
    end

    def self.rotate_all
      sel = @mdl.selection
      return if sel.empty?
      @mdl.start_operation('MagArkido Rotate', true)
      begin
        sel.each do |t|
          next unless t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance)
          angle = [90, 180, 270][rand(3)].degrees
          t.transform! Geom::Transformation.rotation(t.bounds.center, Z_AXIS, angle)
        end
      rescue => e
        puts "MagArkido rotate error: #{e.message}"
      end
      @mdl.commit_operation
    end

    # ---------------------------------------------------------------------------
    # Pattern Manager dialog
    # ---------------------------------------------------------------------------

    def self.files_js
      @files.map { |f| { name: f[:name], path: f[:path], clrs: f[:clrs], ptns: f[:ptns] } }
    end

    def self.build_manager_dialog
      @mgr = UI::HtmlDialog.new(
        dialog_title: 'MagArkido Pattern Manager',
        scrollable:   false,
        resizable:    true,
        width:        680,
        height:       580,
        left:         100,
        top:          80,
        style:        UI::HtmlDialog::STYLE_DIALOG
      )

      @mgr.add_action_callback('applyPattern') do |_ctx, data|
        d = JSON.parse(data)
        pairs = (d['patterns'] || []).map { |p| [p['category'], p['pattern']] }
        @nm = pairs.empty? ? 0 : pairs
        label = @nm == 0 ? 'Auto' : pairs.map { |c, n| "#{n} (#{c})" }.join(', ')
        puts "MagArkido: pattern selection set — #{label}"
      end

      @mgr.add_action_callback('setNoDetail') do |_ctx, data|
        @no_detail = JSON.parse(data)
        puts "MagArkido: no-detail override #{@no_detail ? 'ON' : 'OFF'}"
      end

      # Load a .mgz file into the session (merges with existing patterns)
      @mgr.add_action_callback('importMgzSession') do |_ctx|
        UI.start_timer(0, false) do
          path = UI.openpanel('Load Pattern File', PATTERNS_DIR, 'Pattern Files|*.mgz||')
          next unless path && File.exist?(path)
          begin
            x = JSON.parse(File.read(path))
            unless @files.any? { |f| f[:path] == path }
              file_ptns = {}
              merge_ptns(file_ptns, x['PTNS'] || {})
              @files << { name: File.basename(path), path: path, clrs: x['CLRS'] || {}, ptns: file_ptns }
            end
            (x['CLRS'] || {}).each do |k, v|
              @clrs[k] = v
              m = @mts[k] || @mts.add(k)
              m.color = v.is_a?(Integer) ? Sketchup::Color.new(v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff) : Sketchup::Color.new(v)
            end
            merge_ptns(@ptn, x['PTNS'] || {})
            @mgr.execute_script("refreshAll(#{JSON.generate(@ptn)}, #{JSON.generate(files_js)}, #{JSON.generate(@clrs)})")
          rescue => e
            puts "MagArkido import error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
            UI.messagebox("Could not load pattern file:\n#{e.message}")
          end
        end
      end

      # Remove a loaded file from the session (rebuilds ptn/clrs from remaining files)
      @mgr.add_action_callback('offloadFile') do |_ctx, data|
        path = JSON.parse(data)
        @files.reject! { |f| f[:path] == path }
        @ptn  = {}
        @clrs = {}
        @files.each do |f|
          begin
            x = JSON.parse(File.read(f[:path]))
            (x['CLRS'] || {}).each { |k, v| @clrs[k] = v }
            merge_ptns(@ptn, x['PTNS'] || {})
          rescue => e
            puts "MagArkido: could not re-parse #{f[:name]}: #{e.message}"
          end
        end
        @nm = 0
        @mgr.execute_script("refreshAll(#{JSON.generate(@ptn)}, #{JSON.generate(files_js)}, #{JSON.generate(@clrs)})")
      end

      # Export pattern to a user-chosen location
      @mgr.add_action_callback('exportMgz') do |_ctx, data|
        UI.start_timer(0, false) do
          parsed = JSON.parse(data)
          name   = parsed['name'].to_s.gsub(/[^\w\-]/, '_')
          cat    = parsed['cat'].to_s
          blocks = parsed['blocks']
          clrs   = parsed['clrs'] || {}
          path   = UI.savepanel('Export Pattern', File.expand_path('~'), "#{name}.mgz")
          next unless path
          path += '.mgz' unless path.end_with?('.mgz')
          content = { 'CLRS' => clrs, 'PTNS' => { cat => { name => blocks } } }
          File.write(path, JSON.pretty_generate(content))
          puts "MagArkido: exported #{name} to #{path}"
        end
      end

      # Save pattern to Plugins/Patterns/ folder — merge into current session without reloading
      @mgr.add_action_callback('saveMgz') do |_ctx, data|
        parsed  = JSON.parse(data)
        name    = parsed['name']
        content = parsed['content']
        path    = File.join(PATTERNS_DIR, "#{name}.mgz")
        Dir.mkdir(PATTERNS_DIR) rescue nil
        File.write(path, JSON.pretty_generate(content))
        clrs = content['CLRS'] || {}
        ptns = content['PTNS'] || {}
        file_ptns = {}
        merge_ptns(file_ptns, ptns)
        existing = @files.find { |f| f[:path] == path }
        if existing
          existing[:clrs].merge!(clrs)
          merge_ptns(existing[:ptns], ptns)
        else
          @files << { name: File.basename(path), path: path, clrs: clrs, ptns: file_ptns }
        end
        clrs.each do |k, v|
          @clrs[k] = v
          m = @mts[k] || @mts.add(k)
          m.color = v.is_a?(Integer) ? Sketchup::Color.new(v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff) : Sketchup::Color.new(v)
        end
        merge_ptns(@ptn, ptns)
        puts "MagArkido: saved #{name} to #{path}"
        @mgr.execute_script("refreshAll(#{JSON.generate(@ptn)}, #{JSON.generate(files_js)}, #{JSON.generate(@clrs)})")
      end

      # Remove a single pattern from the in-memory @ptn (does not touch .mgz files)
      @mgr.add_action_callback('deletePattern') do |_ctx, data|
        parsed = JSON.parse(data)
        cat, key = parsed['cat'], parsed['key']
        @ptn[cat]&.delete(key)
        @ptn.delete(cat) if @ptn[cat]&.empty?
        puts "MagArkido: removed pattern #{key} (#{cat}) from session"
      end

      @mgr.add_action_callback('deleteSelection') do |_ctx|
        @mdl.start_operation('MagArkido Delete', true)
        begin
          @mdl.selection.to_a.each { |e| e.erase! rescue nil }
        rescue => err
          puts "MagArkido delete error: #{err.message}"
        end
        @mdl.commit_operation
      end

      @mgr.add_action_callback('testPattern') do |_ctx, data|
        payload  = JSON.parse(data)
        blocks   = payload['blocks']
        ptn_name = payload['name'].to_s
        ptn_cat  = payload['cat'].to_s
        ptn_label = [ptn_name, ptn_cat].reject(&:empty?).join('-')
        @mdl.start_operation('MagArkido Test', true)
        begin
          @mdl.selection.each do |t|
            next unless t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance)
            create(t, blocks, 1, ptn_label)
          end
        rescue => e
          puts "MagArkido test error: #{e.message}"
        end
        @mdl.commit_operation
      end

      @mgr.add_action_callback('absorb') do |_ctx|
        UI.start_timer(0, false) { absorb_to_editor }
      end

      @mgr.add_action_callback('closeDialog') do |_ctx|
        @mgr.close
        @nm = 0
      end

      @mgr.set_on_closed { @nm = 0 }
      @mgr
    end

    def self.reset_mgr
      @mgr.close rescue nil
      @mgr = nil
    end

    def self.show_mgr
      unless @mgr&.visible?
        @mgr&.close rescue nil
        @mgr = build_manager_dialog
      end

      css  = File.read(File.join(RESOURCE_DIR, 'manager.css')) rescue ''
      body = File.read(File.join(RESOURCE_DIR, 'manager.html')) rescue ''

      body.sub!(/<head>.*?<\/head>/m, '')
      body.sub!('<!DOCTYPE html>', '')

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <style>#{css}</style>
          <script>
            window.magarkidoPatterns = #{JSON.generate(@ptn)};
            window.magarkidoPatternsDir = #{JSON.generate(PATTERNS_DIR)};
            window.magarkidoFiles = #{JSON.generate(files_js)};
            window.magarkidoClrs = #{JSON.generate(@clrs)};
          </script>
        </head>
        #{body}
      HTML

      @mgr.set_html(html)
      @mgr.visible? ? @mgr.bring_to_front : @mgr.show
    end

    # ---------------------------------------------------------------------------
    # Toolbar
    # ---------------------------------------------------------------------------

    def self.setup_toolbar
      res = RESOURCE_DIR + '/'
      icons = (1..4).map { |i| res + "icon#{i}.svg" }
      tb = UI::Toolbar.new('MagArkido')

      cm1 = UI::Command.new('Transform All') { transform_all(1) }
      cm1.small_icon = cm1.large_icon = icons[0]
      cm1.status_bar_text = 'Transform selected groups and components with full detail'
      cm1.tooltip = 'Transform All'
      tb.add_item cm1

      cm2 = UI::Command.new('Randomize Rotation') { rotate_all }
      cm2.small_icon = cm2.large_icon = icons[1]
      cm2.status_bar_text = 'Randomly rotate selected groups and components by 90° increments'
      cm2.tooltip = 'Randomize Rotation'
      tb.add_item cm2

      cm3 = UI::Command.new('Reset') { transform_all(0, true) }
      cm3.small_icon = cm3.large_icon = icons[2]
      cm3.status_bar_text = 'Reset selected objects to a plain cube'
      cm3.tooltip = 'Reset'
      tb.add_item cm3

      cm4 = UI::Command.new('Pattern Manager') { show_mgr }
      cm4.small_icon = cm4.large_icon = icons[3]
      cm4.status_bar_text = 'Open Pattern Manager'
      cm4.tooltip = 'Pattern Manager'
      tb.add_item cm4

      cm5 = UI::Command.new('Absorb Selection') { absorb }
      cm5.small_icon = cm5.large_icon = res + 'icon5.svg'
      cm5.status_bar_text = 'Absorb selected group\'s sub-groups as a new pattern'
      cm5.tooltip = 'Absorb Selection as Pattern'
      tb.add_item cm5

      tb.show
    end

    setup_toolbar

end
