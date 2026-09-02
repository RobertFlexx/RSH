require_relative 'security'

module Srsh
  class PluginAPI
    def initialize(app)
      @app = app
    end

    def builtin(name, &block) = @app.builtins.register(name, &block)
    def hook(type, &block) = @app.state.hook(type, &block)
    def alias_command(name, command) = @app.state.aliases[name.to_s] = command.to_s
    def theme(name, values) = @app.theme.register(name, values)
    def state = @app.state
  end

  class Plugins
    MAX_PLUGIN_BYTES = 4 * 1024 * 1024
    attr_reader :loaded

    def initialize(app)
      @app = app
      @loaded = []
    end

    def load_all
      @loaded.clear
      Dir.glob(File.join(@app.paths.plugins, '*.{rsh,rb}')).sort.each { |path| load_file(path) }
    end

    def load_file(path)
      unless Security.private_regular_file?(path)
        @app.err.puts @app.theme.paint("plugin refused (unsafe owner/mode): #{path}", :warn, io: @app.err)
        return false
      end

      case File.extname(path)
      when '.rsh'
        @app.run_script(path, [])
      when '.rb'
        api = PluginAPI.new(@app)
        mod = Module.new
        mod.const_set(:SRSH, api)
        raise Error, 'Ruby plugin too large' if File.size(path) > MAX_PLUGIN_BYTES
        source = File.binread(path, MAX_PLUGIN_BYTES + 1)
        raise Error, 'Ruby plugin too large' if source.bytesize > MAX_PLUGIN_BYTES
        source.force_encoding(Encoding::UTF_8)
        raise Error, 'Ruby plugin is not valid UTF-8' unless source.valid_encoding?
        mod.module_eval(source, path, 1)
      else
        return false
      end
      @loaded << path
      true
    rescue StandardError => e
      @app.err.puts @app.theme.paint("plugin #{File.basename(path)}: #{e.class}: #{e.message}", :error, io: @app.err)
      false
    end
  end
end
