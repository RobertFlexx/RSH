require 'mkmf'
$CFLAGS << ' -O3' unless $CFLAGS.include?('-O')
create_makefile('srsh_native')
