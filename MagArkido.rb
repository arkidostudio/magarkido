require 'sketchup.rb'
require 'extensions.rb'

ext = SketchupExtension.new('MagArkido', 'MagArkido/MagArkido_Core.rb')
ext.description = 'Generates building shapes from selected groups and components.'
ext.version     = '0.5.0'
ext.copyright   = '2019-2025'
Sketchup.register_extension(ext, true)
