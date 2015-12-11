# this is an abstract class
package backend::baseclass;
use strict;
use warnings;
use threads;
use Carp qw(cluck carp confess);
use JSON qw( to_json );
use File::Copy qw(cp);
use File::Basename;
use Time::HiRes qw(gettimeofday);
use bmwqemu;
use IO::Select;
require IPC::System::Simple;
use autodie qw(:all);

use Data::Dumper;
use feature qw(say);

my $framecounter = 0;    # screenshot counter
our $MAGIC_PIPE_CLOSE_STRING = "xxxQUITxxx\n";

# should be a singleton - and only useful in backend thread
our $backend;

use parent qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(
    qw(
      update_request_interval last_update_request
      screenshot_interval last_screenshot last_screenshot_name_ last_image
      reference_screenshot)
);

sub new {
    my $class = shift;
    my $self = bless({class => $class}, $class);
    $self->{started}       = 0;
    $self->{serialfile}    = "serial0";
    $self->{serial_offset} = 0;
    return $self;
}

# runs in the thread to deserialize VNC commands
sub handle_command {

    my ($self, $cmd) = @_;

    my $func = $cmd->{cmd};
    unless ($self->can($func)) {
        die "not supported command: $func";
    }
    return $self->$func($cmd->{arguments});
}

sub die_handler {
    my $msg = shift;
    cluck "DIE $msg\n";
    $backend->stop_vm();
    $backend->close_pipes();
}



sub run {
    my ($self, $cmdpipe, $rsppipe) = @_;

    die "there can be only one!" if $backend;
    $backend = $self;

    $SIG{__DIE__} = \&die_handler;

    my $io = IO::Handle->new();
    $io->fdopen($cmdpipe, "r") || die "r fdopen $!";
    $self->{cmdpipe} = $io;

    $io = IO::Handle->new();
    $io->fdopen($rsppipe, "w") || die "w fdopen $!";
    $rsppipe = $io;
    $io->autoflush(1);
    $self->{rsppipe} = $io;

    printf STDERR "$$: cmdpipe %d, rsppipe %d\n", fileno($self->{cmdpipe}), fileno($self->{rsppipe});

    bmwqemu::diag "started mgmt loop with thread id " . threads->tid();

    $self->{select} = IO::Select->new();
    $self->{select}->add($self->{cmdpipe});

    $self->last_update_request("-Inf" + 0);
    $self->last_screenshot("-Inf" + 0);
    $self->screenshot_interval($bmwqemu::vars{SCREENSHOTINTERVAL} || .5);
    $self->update_request_interval($self->screenshot_interval());

    for my $console (values %{$testapi::distri->{consoles}}) {
        # tell the consoles who they need to talk to (in this thread)
        $console->backend($self);
    }

    $self->run_capture_loop($self->{select});

    bmwqemu::diag("management thread exit at " . POSIX::strftime("%F %T", gmtime));
}

use List::Util qw(min);

=head2 run_capture_loop(\@select, $timeout, $update_request_interval, $screenshot_interval)

=out

=item select

IO::Select object that is polled when given

=item timeout

run the loop this long in seconds, indefinitely if undef, or until the
$self->{cmdpipe} is closed, whichever occurs first.

=item update_request_interval

space out update polls for this interval in seconds, i.e. update the
internal buffers this often.

If unset, use $self->{update_request_interval}.  For the main capture
loop $self->{update_request_interval} can be modified while this loop
is running, e.g. to poll more often for a stretch of time.

=item screenshot_interval

space out screen captures for this interval in seconds, i.e. save a
screenshot from the buffers this often.

If unset, use $self->{screenshot_interval}.  For the main capture
loop, $self->{screenshot_interval} can be modified while this loop is
running, e.g. to do some fast or slow motion.

=back

=cut

sub run_capture_loop {
    my ($self, $select, $timeout, $update_request_interval, $screenshot_interval) = @_;
    my $starttime = gettimeofday;
    eval {
        while (1) {

            last if (!$self->{cmdpipe});

            my $now = gettimeofday;

            my $time_to_timeout = "Inf" + 0;
            if (defined $timeout) {
                $time_to_timeout = $timeout - ($now - $starttime);

                last if $time_to_timeout <= 0;
            }

            my $time_to_update_request = ($update_request_interval // $self->update_request_interval) - ($now - $self->last_update_request);
            if ($time_to_update_request <= 0) {
                $self->request_screen_update();
                $self->last_update_request($now);
                $time_to_update_request = ($update_request_interval // $self->update_request_interval);
            }

            my $time_to_screenshot = ($screenshot_interval // $self->screenshot_interval) - ($now - $self->last_screenshot);
            if ($time_to_screenshot <= 0) {
                $self->capture_screenshot();
                $self->last_screenshot($now);
                $time_to_screenshot = ($screenshot_interval // $self->screenshot_interval);
            }

            my $time_to_next = min($time_to_screenshot, $time_to_update_request, $time_to_timeout);
            if (defined $select) {
                my @ready = $select->can_read($time_to_next);

                for my $fh (@ready) {
                    unless ($self->check_socket($fh)) {
                        die "huh! $fh\n";
                    }
                }
            }
            else {
                # "select" used to emulate "sleep"
                # (coolo) no idea why susanne did this
                select(undef, undef, undef, $time_to_next);    ## no critic
            }
        }
    };

    if ($@) {
        bmwqemu::diag "capture loop failed $@";
        $self->close_pipes();
    }
}

# new api

sub start_encoder {
    my ($self) = @_;

    return if $bmwqemu::vars{NOVIDEO};

    my $cwd = Cwd::getcwd();
    open($self->{encoder_pipe}, "|-", "nice -n 19 $bmwqemu::scriptdir/videoencoder $cwd/video.ogv");
}

sub get_last_mouse_set {
    my $self = shift;
    return $self->{mouse};
}

sub post_start_hook {
    my ($self) = @_;

    # ignored by default
    return 0;
}

sub start_vm {
    my ($self) = @_;
    $self->{mouse} = {x => undef, y => undef};
    $self->{started} = 1;
    $self->start_encoder();
    return $self->do_start_vm();
}

sub stop_vm {
    my $self = shift;
    if ($self->{started}) {
        close($self->{encoder_pipe}) if $self->{encoder_pipe};
        # backend.run might have disappeared already in case of failed builds
        no autodie qw(unlink);
        unlink('backend.run');
        $self->do_stop_vm();
        $self->{started} = 0;
    }
    $self->close_pipes();    # does not return
    return {};
}

sub alive {
    my $self = shift;
    if ($self->{started}) {
        if ($self->file_alive() and $self->raw_alive()) {
            return 1;
        }
        else {
            bmwqemu::diag("ALARM: backend.run got deleted! - exiting...");
            alarm 3;
        }
    }
    return 0;
}

my $iscrashedfile = 'backend.crashed';
sub unlink_crash_file {
    unlink($iscrashedfile) if -e $iscrashedfile;
}

sub write_crash_file {
    open(my $fh, ">", $iscrashedfile);
    print $fh "crashed\n";
    close $fh;
}

# new api end

# virtual methods
sub notimplemented() { confess "backend method not implemented" }

sub power {

    # parameters: acpi, reset, (on), off
    notimplemented;
}

sub insert_cd { notimplemented }
sub eject_cd  { notimplemented }

sub do_start_vm {
    # start up the vm
    notimplemented;
}

sub do_stop_vm { notimplemented }

sub stop              { notimplemented }
sub cont              { notimplemented }
sub do_savevm         { notimplemented }
sub do_loadvm         { notimplemented }
sub do_extract_assets { notimplemented }
sub status            { notimplemented }

## MAY be overwritten:

sub get_backend_info {
    # returns hashref
    my ($self) = @_;
    return {};
}

sub cpu_stat {
    # vm's would return
    # (userstat, systemstat)
    return [];
}

sub enqueue_screenshot {
    my ($self, $image) = @_;

    return unless $image;

    $image = $image->scale(1024, 768);

    $framecounter++;

    my $filename = $bmwqemu::screenshotpath . sprintf("/shot-%010d.png", $framecounter);
    my $lastlink = $bmwqemu::screenshotpath . "/last.png";

    my $lastscreenshot = $self->last_image;

    # link identical files to save space
    my $sim = 0;
    $sim = $lastscreenshot->similarity($image) if $lastscreenshot;

    # 54 is based on t/data/user-settings-*
    if ($sim > 54) {
        symlink(basename($self->last_screenshot_name_), $filename) || warn "failed to create $filename symlink: $!\n";
    }
    else {    # new
        $image->write($filename) || die "write $filename";
        $self->last_image($image);
        $self->last_screenshot_name_($filename);
        no autodie qw(unlink);
        unlink($lastlink);
        symlink(basename($self->last_screenshot_name_), $lastlink);
    }
    if ($self->{encoder_pipe}) {
        if ($sim > 50) {    # we ignore smaller differences
            $self->{encoder_pipe}->print("R\n");
        }
        else {
            my $name = $self->last_screenshot_name_;
            $self->{encoder_pipe}->print("E $name\n");
        }
        $self->{encoder_pipe}->flush();
    }
}

sub close_pipes {
    my ($self) = @_;

    if ($self->{cmdpipe}) {
        close($self->{cmdpipe}) || die "close $!\n";
        $self->{cmdpipe} = undef;
    }

    return unless $self->{rsppipe};

    # XXX: perl does not really close the fd here due to threads!?
    print "sending magic and exit\n";
    $self->{rsppipe}->print($MAGIC_PIPE_CLOSE_STRING);
    close($self->{rsppipe}) || die "close $!\n";
    threads->exit();
}

# this is called for all sockets ready to read from
sub check_socket {
    my ($self, $fh) = @_;

    if ($self->{cmdpipe} && $fh == $self->{cmdpipe}) {
        my $cmd = backend::driver::_read_json($self->{cmdpipe});

        if ($cmd->{cmd}) {
            my $rsp = $self->handle_command($cmd);
            if ($self->{rsppipe}) {    # the command might have closed it
                my $JSON = JSON->new()->convert_blessed();
                my $json = $JSON->encode({rsp => $rsp});
                $self->{rsppipe}->print("$json\n");
            }
        }
        else {
            use Data::Dumper;
            die "no command in " . Dumper($cmd);
        }
        return 1;
    }
    return 0;
}

###################################################################
## access other consoles from the test case thread

# There can be two vnc backends (local Xvnc or remote vnc) and
# there can be several terminals on the local Xvnc.
#
# switching means: turn to the right vnc and if it's the Xvnc,
# iconify/deiconify the right x3270 terminal window.
#
# FIXME? for now, we just raise the terminal window to the front on
# the local-Xvnc DISPLAY.
#
# should we hide the other windows, somehow?
#if exists $self->{current_console} ...
# my $current_window_id = $self->{current_console}->{window_id};
# if (defined $current_window_id) {
#     system("DISPLAY=$display xdotool windowminimize --sync $current_window_id");
# }
#-> select

sub select_console {
    my ($self, $args) = @_;
    my $testapi_console = $args->{testapi_console};

    my $selected_console = $self->console($testapi_console);
    my $activated        = $selected_console->select;

    $self->{current_console} = $selected_console;
    $self->{current_screen}  = $selected_console->screen;
    $self->capture_screenshot();
    return {activated => $activated};
}

sub reset_console {
    my ($self, $args) = @_;
    $self->console($args->{testapi_console})->reset;
    return;
}

sub deactivate_console {
    my ($self, $args) = @_;
    my $testapi_console = $args->{testapi_console};

    my $console_info = $self->console($testapi_console);
    if (defined $self->{current_console} && $self->{current_console} == $console_info) {
        $self->{current_console} = undef;
    }
    $console_info->disable();
    return;
}

sub request_screen_update {
    my ($self) = @_;

    return $self->bouncer('request_screen_update', undef);
}

sub console {
    my ($self, $testapi_console) = @_;

    my $ret = $testapi::distri->{consoles}->{$testapi_console};
    unless ($ret) {
        carp "console $testapi_console does not exist";
    }
    return $ret;
}

sub bouncer {
    my ($self, $call, $args) = @_;
    # forward to the current VNC console
    return unless $self->{current_screen};
    return $self->{current_screen}->$call($args);
}

sub send_key() {
    my ($self, $args) = @_;
    return $self->bouncer('send_key', $args);
}

sub type_string() {
    my ($self, $args) = @_;
    return $self->bouncer('type_string', $args);
}

sub mouse_set() {
    my ($self, $args) = @_;
    return $self->bouncer('mouse_set', $args);
}

sub mouse_hide() {
    my ($self, $args) = @_;
    return $self->bouncer('mouse_hide', $args);
}

sub mouse_button() {
    my ($self, $args) = @_;
    return $self->bouncer('mouse_button', $args);
}


sub capture_screenshot {
    my ($self) = @_;
    return unless $self->{current_screen};

    my $screen = $self->{current_screen}->current_screen();
    $self->enqueue_screenshot($screen) if $screen;
    return;
}

###################################################################
# this is used by backend::console_proxy
sub proxy_console_call {
    my ($self, $wrapped_call) = @_;

    my ($console, $function, $args) = @$wrapped_call{qw(console function args)};
    $console = $self->console($console);

    my $wrapped_result = {};

    eval {
        # Do not die in here.
        # Move the decision to actually die to the server side instead.
        # For this ignore backend::baseclass::die_handler.
        local $SIG{__DIE__} = 'DEFAULT';
        $wrapped_result->{result} = $console->$function(@$args);
    };

    if ($@) {
        $wrapped_result->{exception} = join("\n", bmwqemu::pp($wrapped_call), $@);
    }

    return $wrapped_result;
}

=head2 set_serial_offset

Determines the starting offset within the serial file - so that we do not check the
previous test's serial output. Call this before you start doing something new

=cut

sub set_serial_offset {
    my ($self, $args) = @_;

    $self->{serial_offset} = -s $self->{serialfile};
    return $self->{serial_offset};
}


=head2 serial_text

Returns the output on the serial device since the last call to set_serial_offset

=cut

sub serial_text {
    my ($self) = @_;

    open(my $SERIAL, "<", $self->{serialfile});
    seek($SERIAL, $self->{serial_offset}, 0);
    local $/;
    my $data = <$SERIAL>;
    close($SERIAL);
    return $data;
}

sub wait_serial {
    my ($self, $args) = @_;

    my $regexp  = $args->{regexp};
    my $timeout = $args->{timeout};
    my $matched = 0;
    my $str;

    if (ref $regexp ne 'ARRAY') {
        $regexp = [$regexp];
    }
    my $initial_time = time;
    while (time < $initial_time + $timeout) {
        $str = $self->serial_text();
        for my $r (@$regexp) {
            if (ref $r eq 'Regexp') {
                $matched = $str =~ $r;
            }
            else {
                $matched = $str =~ m/$r/;
            }
            if ($matched) {
                $regexp = "$r";
                last;
            }
        }
        last if ($matched);
        # 1 second timeout, .19 froh's magic number :)
        $self->run_capture_loop(undef, 1, .19);
    }
    $self->set_serial_offset();
    return {matched => $matched, string => $str};
}

# set_reference_screenshot and similiarity_to_reference are necessary to
# implement wait_still and wait_changed functions in the tests without having
# to transfer the screenshot into the test thread
sub set_reference_screenshot {
    my ($self, $args) = @_;

    $self->reference_screenshot($self->last_image);
    return;
}


sub similiarity_to_reference {
    my ($self, $args) = @_;
    if (!$self->reference_screenshot || !$self->last_image) {
        return {sim => 10000};
    }
    return {sim => $self->reference_screenshot->similarity($self->last_image)};
}

sub wait_idle {
    my ($self, $args) = @_;
    my $timeout = $args->{timeout};

    bmwqemu::diag("wait_idle sleeping for $timeout seconds");
    $self->run_capture_loop(undef, $timeout);
    return;
}

sub assert_screen {
    my ($self, $args) = @_;
    my $mustmatch = $args->{mustmatch};
    my $timeout = $args->{timeout} // $bmwqemu::default_timeout;

    # get the array reference to all matching needles
    my $needles = [];
    my @tags;
    if (ref($mustmatch) eq "ARRAY") {
        my @a = @$mustmatch;
        while (my $n = shift @a) {
            if (ref($n) eq '') {
                push @tags, split(/ /, $n);
                $n = needle::tags($n);
                push @a, @$n if $n;
                next;
            }
            unless (ref($n) eq 'needle' && $n->{name}) {
                warn "invalid needle passed <" . ref($n) . "> " . pp($n);
                next;
            }
            push @$needles, $n;
        }
    }
    elsif ($mustmatch) {
        $needles = needle::tags($mustmatch) || [];
        @tags = ($mustmatch);
    }

    {    # remove duplicates
        my %h = map { $_ => 1 } @tags;
        @tags = sort keys %h;
    }
    $mustmatch = join('_', @tags);

    if (!@$needles) {
        diag("NO matching needles for $mustmatch");
    }

    # we keep a collection of mismatched screens
    my $failed_screens = [];

    my $img          = $self->last_image;
    my $img_filename = $self->last_screenshot_name_;
    my $oldimg;
    my $old_search_ratio = 0;
    my $failed_candidates;
    for (my $n = $timeout; $n >= 0; $n--) {
        my $search_ratio = 0.02;
        $search_ratio = 1 if ($n % 6 == 5) || ($n == 0);

        if ($oldimg) {
            $self->run_capture_loop(undef, 1);
            $img          = $self->last_image;
            $img_filename = $self->last_screenshot_name_;
            if ($oldimg == $img && $search_ratio <= $old_search_ratio) {    # no change, no need to search
                diag(sprintf("no change %d", $n));
                next;
            }
        }
        my $foundneedle;
        ($foundneedle, $failed_candidates) = $img->search($needles, 0, $search_ratio);
        if ($foundneedle) {
            return {filename => $img_filename, found => $foundneedle, tags => \@tags, candidates => $failed_candidates};
        }

        if ($search_ratio == 1) {
            # save only failures where the whole screen has been searched
            # results of partial searching are rather confusing

            # as the images create memory pressure, we only save quite different images
            # the last screen is handled automatically and the first needle is only interesting
            # if there are no others
            my $sim = 29;
            if ($failed_screens->[-1] && $n > 0) {
                $sim = $failed_screens->[-1]->[0]->similarity($img);
            }
            if ($sim < 30) {
                push(@$failed_screens, [$img, $failed_candidates, $n, $sim, $img_filename]);
            }
            # clean up every once in a while to avoid excessive memory consumption.
            # The value here is an arbitrary limit.
            if (@$failed_screens > 60) {
                _reduce_to_biggest_changes($failed_screens, 20);
            }
        }
        diag("no match $n");
        $oldimg           = $img;
        $old_search_ratio = $search_ratio;
    }

    my $final_mismatch = $failed_screens->[-1];
    _reduce_to_biggest_changes($failed_screens, 20);
    # only append the last mismatch if it's different to the last one in the reduced list
    my $new_final = $failed_screens->[-1];
    if ($new_final != $final_mismatch) {
        my $sim = $new_final->[0]->similarity($final_mismatch->[0]);
        push(@$failed_screens, $final_mismatch) if ($sim < 50);
    }

    my @json_fails;
    for my $l (@$failed_screens) {
        my ($img, $failed_candidates, $testtime, $similarity, $filename) = @$l;
        my $h = {
            candidates => $failed_candidates,
            filename   => $filename
        };
        push(@json_fails, $h);
    }

    return {failed_screens => \@json_fails, tags => \@tags};
}

sub _reduce_to_biggest_changes {
    my ($imglist, $limit) = @_;

    return if @$imglist <= $limit;

    my $first = shift @$imglist;
    @$imglist = (sort { $b->[3] <=> $a->[3] } @$imglist)[0 .. (@$imglist > $limit ? $limit - 1 : $#$imglist)];
    unshift @$imglist, $first;

    # now sort for test time
    @$imglist = sort { $b->[2] <=> $a->[2] } @$imglist;

    # recalculate similarity
    for (my $i = 1; $i < @$imglist; ++$i) {
        $imglist->[$i]->[3] = $imglist->[$i - 1]->[0]->similarity($imglist->[$i]->[0]);
    }

    return;
}

sub freeze_vm {
    # qemu specific - all other backends will crash
    return $backend->handle_qmp_command({"execute" => "stop"});
}

sub cont_vm {
    return $backend->handle_qmp_command({"execute" => "cont"});
}

sub last_screenshot_name {
    my ($self, $args) = @_;
    return {filename => $self->last_screenshot_name_};
}

1;
# vim: set sw=4 et:
