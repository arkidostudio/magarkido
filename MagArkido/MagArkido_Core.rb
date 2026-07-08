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

    def self.initial
      require 'json'
      @mdl = Sketchup.active_model
      @mts = @mdl.materials
      @nm  = 0  # 0 = auto-choose; [category, key] = specific pattern
      @cb  = DEFAULT_BLOCK

      merged = { 'CLRS' => {}, 'PTNS' => {} }

      Dir[File.join(PATTERNS_DIR, '*.mgz')].each do |f|
        begin
          x = JSON.parse(File.read(f))
          merged['CLRS'].merge!(x['CLRS']) if x['CLRS']
          (x['PTNS'] || {}).each do |cat, ptns|
            next unless ptns.is_a?(Hash)
            merged['PTNS'][cat] ||= {}
            merged['PTNS'][cat].merge!(ptns)
          end
        rescue => e
          puts "MagArkido: could not parse #{File.basename(f)}: #{e.message}"
        end
      end

      merged['CLRS'].each do |k, v|
        m = @mts[k] || @mts.add(k)
        m.color = v.is_a?(Integer) ? Sketchup::Color.new(v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff) : Sketchup::Color.new(v)
      end

      @ptn = merged['PTNS']
    end

    initial

    # ---------------------------------------------------------------------------
    # Safe expression resolver — replaces eval()
    # Tokens: numeric literals, r1/r2/r3, lv(t,n), block field names (h,w,d,x,y,z,seg,offset),
    # and arithmetic operators. Pass block_fields (the raw block array) to allow
    # cross-field references like "h*0.5" in the w expression.
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
      vs = fs[f].vertices
      vs.each { |v| ps << v.position }
      eg = vs[0].edges - fs[f].edges
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
      fs[f].edges.each do |e|
        p, vt = e.start.position, e.line[1]
        vt.length = e.length / n
        (1...n - s).each { |i| p += vt; ps << p if i > s }
      end
      vt = fs[f].normal.reverse
      vt.length = (fs[f].vertices[0].edges - fs[f].edges)[0].length
      li = ps.map { |p| [p, p + vt] }
      li.each { |l| g.entities.add_edges l }
    end

    # Returns floor count for a given target entity and floor height (meters)
    def self.lv(t, m)
      (t.bounds.depth / m * 0.0254).round(0)
    end

    # ---------------------------------------------------------------------------
    # Normalise a pattern entry to a plain array regardless of source format
    # Accepts both legacy positional arrays and new named-key hashes
    # ---------------------------------------------------------------------------
    def self.normalise_block(b)
      return b if b.is_a?(Array)
      NAMED_KEYS.map { |k| b[k] }
    end

    # ---------------------------------------------------------------------------
    # Create building geometry inside target group/component
    # ---------------------------------------------------------------------------
    def self.create(t, pattern_data, detail = 0)
      case t
      when Sketchup::Group             then e = t.entities.add_group
      when Sketchup::ComponentInstance then e = t.definition.entities.add_group
      else return
      end

      # Capture target bounds now — before geometry is added to e, which would
      # inflate t.definition.bounds and produce a wrong scale factor.
      target_w = t.definition.bounds.width
      target_h = t.definition.bounds.height
      target_d = t.definition.bounds.depth

      r1, r2, r3 = rand(2), rand(2), rand(2)

      blocks = pattern_data.map { |b| normalise_block(b).dup }

      blocks.each do |n|
        # First pass: resolve r1/r2/r3 and lv() without cross-field references
        (0..10).each do |i|
          next if i == 6
          n[i] = resolve(n[i], t, r1, r2, r3) if n[i].is_a?(String)
        end
        # Second pass: resolve any remaining strings using now-numeric peer values (e.g. "h*0.5")
        (0..10).each do |i|
          next if i == 6
          n[i] = resolve(n[i], t, r1, r2, r3, n) if n[i].is_a?(String)
        end
      end

      blocks.each do |n|
        c = cube(e.entities, Geom::Point3d.new(n[0], n[1], n[2]), n[3], n[4], n[5])
        c.material = n[6]
        unless detail == 0 && n[7] == 0
          dv1(c, n[8], n[9], n[10]) if n[7] == 1
          dv2(c, n[8], n[9], n[10]) if n[7] == 2
        end
      end

      e.transform! Geom::Transformation.rotation(e.bounds.center, Z_AXIS, 90.degrees * rand(4))
      e.transform! Geom::Transformation.new(e.bounds.min).inverse

      s = Geom::Transformation.scaling(
        target_w / e.bounds.width,
        target_h / e.bounds.height,
        target_d / e.bounds.depth
      )
      e.transform! s

      t.definition.entities.each { |x| x.erase! if x != e }
      f = e.explode
      f[0].explode if pattern_data[0] && normalise_block(pattern_data[0])[7] == 0
    end

    # ---------------------------------------------------------------------------
    # Auto-select a pattern based on height and entity type
    # @nm = 0                           → auto by height/type
    # @nm = [[cat,key], [cat,key], ...] → randomly pick from user's multi-selection
    # ---------------------------------------------------------------------------
    def self.choose(t)
      if @nm.is_a?(Array) && !@nm.empty?
        pair = @nm[rand(@nm.size)]
        return ((@ptn[pair[0]] || {})[pair[1]]) || @cb
      end
      # Auto: pick randomly from all available patterns across all categories
      all = @ptn.values.flat_map(&:values).select { |v| v.is_a?(Array) }
      all.empty? ? @cb : all[rand(all.size)]
    end

    # ---------------------------------------------------------------------------
    # Absorb — convert nested sub-groups in the selected entity into a pattern
    # ---------------------------------------------------------------------------
    def self.resolve_mat_key(entity)
      mat = entity.material
      return 'BDY' unless mat
      name = mat.name.upcase
      %w[BDY TOP BTM SLD].include?(name) ? name : 'BDY'
    end

    # Extract blocks from selected entity's sub-groups and send to the editor in JS.
    # No prompts — name/category are filled in the editor UI.
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
          'x' => (b.min.x - min_x).round(2),
          'y' => (b.min.y - min_y).round(2),
          'z' => (b.min.z - min_z).round(2),
          'w' => b.width.round(2),
          'd' => b.height.round(2),
          'h' => b.depth.round(2),
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

      total   = sel.select { |t| t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance) }.size
      done    = 0
      changed = []

      @mdl.start_operation('MagArkido Transform', true)
      begin
        sel.each do |t|
          next unless t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance)
          pattern = reset ? @cb : choose(t)
          unless t.is_a?(Sketchup::ComponentInstance) && changed.include?(t.definition)
            create(t, pattern, detail)
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

    # ---------------------------------------------------------------------------
    # Pattern Manager dialog
    # ---------------------------------------------------------------------------

    def self.build_manager_dialog
      @mgr = UI::HtmlDialog.new(
        dialog_title: 'MagArkido Pattern Manager',
        scrollable:   false,
        resizable:    true,
        width:        620,
        height:       560,
        left:         100,
        top:          80,
        style:        UI::HtmlDialog::STYLE_DIALOG
      )

      # Apply pattern selection and immediately transform.
      # JS sends { patterns: [{category, pattern}, ...] } — empty means auto.
      @mgr.add_action_callback('applyPattern') do |_ctx, data|
        d = JSON.parse(data)
        pairs = (d['patterns'] || []).map { |p| [p['category'], p['pattern']] }
        @nm = pairs.empty? ? 0 : pairs
        transform_all(1)
      end

      # Import a .mgz from anywhere on disk and merge into the current session.
      @mgr.add_action_callback('importMgzSession') do |_ctx|
        UI.start_timer(0, false) do
          path = UI.openpanel('Load Pattern File', PATTERNS_DIR, 'Pattern Files|*.mgz||')
          next unless path && File.exist?(path)
          begin
            x = JSON.parse(File.read(path))
            # Merge all categories from the file
            added = 0
            (x['PTNS'] || {}).each do |cat, ptns|
              next unless ptns.is_a?(Hash)
              @ptn[cat] ||= {}
              @ptn[cat].merge!(ptns)
              added += ptns.size
            end
            # Merge and apply materials from CLRS
            (x['CLRS'] || {}).each do |k, v|
              m = @mts[k] || @mts.add(k)
              m.color = v.is_a?(Integer) ? Sketchup::Color.new(v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff) : Sketchup::Color.new(v)
            end
            puts "MagArkido: imported #{added} pattern(s) from #{File.basename(path)}"
            @mgr.execute_script("refreshPatterns(#{JSON.generate(@ptn)})")
          rescue => e
            puts "MagArkido import error: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
            UI.messagebox("Could not load pattern file:\n#{e.message}")
          end
        end
      end

      # Import a .mgz file via system file picker
      @mgr.add_action_callback('importMgz') do |_ctx|
        # UI.openpanel must run on the main thread — defer via timer
        UI.start_timer(0, false) do
          path = UI.openpanel('Import Pattern File', PATTERNS_DIR, 'Pattern Files|*.mgz||')
          next unless path && File.exist?(path)
          begin
            data = JSON.parse(File.read(path))
            @mgr.execute_script("receiveImport(#{JSON.generate(data)}, #{JSON.generate(File.basename(path))})")
          rescue JSON::ParserError => e
            UI.messagebox("Could not read pattern file:\n#{e.message}")
          end
        end
      end

      # Save a pattern written in the editor
      @mgr.add_action_callback('saveMgz') do |_ctx, data|
        parsed = JSON.parse(data)
        name   = parsed['name']
        path   = File.join(PATTERNS_DIR, "#{name}.mgz")
        File.write(path, JSON.pretty_generate(parsed['content']))
        initial
        @mgr.execute_script("refreshPatterns(#{JSON.generate(@ptn)})")
      end

      # Delete the current SketchUp selection
      @mgr.add_action_callback('deleteSelection') do |_ctx|
        @mdl.start_operation('MagArkido Delete', true)
        begin
          @mdl.selection.to_a.each { |e| e.erase! rescue nil }
        rescue => err
          puts "MagArkido delete error: #{err.message}"
        end
        @mdl.commit_operation
      end

      # Apply pattern blocks to selection without saving (live test)
      @mgr.add_action_callback('testPattern') do |_ctx, data|
        blocks = JSON.parse(data)
        @mdl.start_operation('MagArkido Test', true)
        begin
          @mdl.selection.each do |t|
            next unless t.is_a?(Sketchup::Group) || t.is_a?(Sketchup::ComponentInstance)
            create(t, blocks, 1)
          end
        rescue => e
          puts "MagArkido test error: #{e.message}"
        end
        @mdl.commit_operation
      end

      # Absorb the selected group's sub-groups as a new pattern (triggered from dialog)
      # UI.inputbox and UI.savepanel must be deferred via timer when inside a dialog callback
      @mgr.add_action_callback('absorb') do |_ctx|
        UI.start_timer(0, false) { absorb_to_editor }
      end

      @mgr.set_on_closed { @nm = 0 }
      @mgr
    end

    # Rebuild and inject the full HTML with pattern data embedded so there's no
    # async handshake — patterns are available the moment the page loads.
    def self.show_mgr
      @mgr ||= build_manager_dialog

      css  = File.read(File.join(RESOURCE_DIR, 'manager.css')) rescue ''
      body = File.read(File.join(RESOURCE_DIR, 'manager.html')) rescue ''

      # Strip the original <head> block and replace it with an inline one
      body.sub!(/<head>.*?<\/head>/m, '')
      body.sub!('<!DOCTYPE html>', '')
      body.sub!('<html', '<html')  # no-op, keeps tag

      html = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <style>#{css}</style>
          <script>
            window.magarkidoPatterns    = #{JSON.generate(@ptn)};
            window.magarkidoPatternsDir = #{JSON.generate(PATTERNS_DIR)};
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

      cm2 = UI::Command.new('Simple Transform') { transform_all(0) }
      cm2.small_icon = cm2.large_icon = icons[1]
      cm2.status_bar_text = 'Transform selected groups and components without facade detail'
      cm2.tooltip = 'Simple Transform'
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
