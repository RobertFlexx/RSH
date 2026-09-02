require 'tempfile'

module Srsh
  module Security
    module_function

    def private_regular_file?(path)
      st = File.lstat(path)
      return false unless st.file?
      return false if st.symlink?
      return false unless st.uid == Process.uid
      (st.mode & 0o022).zero?
    rescue SystemCallError
      false
    end

    def safe_auto_source?(path)
      !File.exist?(path) || private_regular_file?(path)
    end

    def atomic_write(path, data, mode: 0o600)
      dir = File.dirname(path)
      Dir.mkdir(dir, 0o700) unless Dir.exist?(dir)
      tmp = "#{path}.tmp.#{$$}.#{rand(1 << 30)}"
      flags = File::WRONLY | File::CREAT | File::EXCL
      File.open(tmp, flags, mode) do |f|
        f.write(data)
        f.flush
        f.fsync rescue nil
      end
      File.rename(tmp, path)
      File.chmod(mode, path) rescue nil
      true
    ensure
      File.unlink(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end
  end
end
