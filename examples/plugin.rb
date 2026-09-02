SRSH.builtin('wsg') do |args|
  puts "wsg #{args[1] || 'gng'} :P"
  0
end

SRSH.hook(:post_cmd) do |command, status|
  # Ruby plugins have the full power of Ruby. Treat them as trusted code.
end
