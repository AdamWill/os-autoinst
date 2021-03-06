#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use Try::Tiny;
use File::Basename;
use Cwd 'abs_path';

# optional but very useful
eval 'use Test::More::Color';                 ## no critic
eval 'use Test::More::Color "foreground"';    ## no critic

my $toplevel_dir = abs_path(dirname(__FILE__) . '/..');
my $data_dir     = "$toplevel_dir/t/data/";
my $pool_dir     = "$toplevel_dir/t/pool/";

chdir($pool_dir);
open(my $var, '>', 'vars.json');
print $var <<EOV;
{
   "ARCH" : "i386",
   "BACKEND" : "qemu",
   "QEMU" : "i386",
   "QEMU_NO_KVM" : "1",
   "QEMU_NO_TABLET" : "1",
   "QEMU_NO_FDC_SET" : "1",
   "CASEDIR" : "$data_dir/tests",
   "ISO" : "$data_dir/pitux-0.3.2.iso",
   "CDMODEL" : "ide-cd",
   "HDDMODEL" : "ide-drive",
   "VERSION" : "1",
}
EOV
close($var);
# create screenshots
open($var, '>', 'live_log');
close($var);
is(system("perl $toplevel_dir/isotovideo -d"), 0, 'Test executed fine');

done_testing();
