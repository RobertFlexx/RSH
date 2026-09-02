require 'fileutils'

module Srsh
  class Paths
    attr_reader :home, :root, :plugins, :themes, :config, :history, :history_v1, :rc, :theme_state

    def initialize(home = Dir.home)
      @home = home
      @root = File.join(home, '.srsh')
      @plugins = File.join(root, 'plugins')
      @themes = File.join(root, 'themes')
      @config = File.join(root, 'config')
      # Keep the original SRSH history location. 1.0.0 briefly moved it into
      # ~/.srsh/history; History imports that file so neither generation is lost.
      @history = File.join(home, '.srsh_history')
      @history_v1 = File.join(root, 'history')
      @rc = File.join(home, '.srshrc')
      @theme_state = File.join(root, 'theme')
    end

    def ensure!
      FileUtils.mkdir_p(root, mode: 0o700)
      FileUtils.mkdir_p(plugins, mode: 0o700)
      FileUtils.mkdir_p(themes, mode: 0o700)
      [root, plugins, themes].each { |p| File.chmod(0o700, p) rescue nil }
      self
    end
  end
end
