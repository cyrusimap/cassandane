#!/usr/bin/perl
#
#  Copyright (c) 2011-2017 FastMail Pty Ltd. All rights reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in
#     the documentation and/or other materials provided with the
#     distribution.
#
#  3. The name "Fastmail Pty Ltd" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
#      FastMail Pty Ltd
#      PO Box 234
#      Collins St West 8007
#      Victoria
#      Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Fastmail Pty. Ltd."
#
#  FASTMAIL PTY LTD DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
#  INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY  AND FITNESS, IN NO
#  EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE FOR ANY SPECIAL, INDIRECT
#  OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
#  USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
#  TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
#  OF THIS SOFTWARE.
#

package Cassandane::Instance;
use strict;
use warnings;
use Config;
use Data::Dumper;
use Errno qw(ENOENT);
use File::Path qw(mkpath rmtree);
use File::Find qw(find);
use File::Basename;
use File::stat;
use POSIX qw(geteuid :signal_h :sys_wait_h :errno_h);
use DateTime;
use BSD::Resource;
use Cwd qw(abs_path getcwd);
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Util;
use JSON;
use HTTP::Daemon;
use DBI;
use Time::HiRes qw(usleep);

use lib '.';
use Cassandane::Util::DateTime qw(to_iso8601);
use Cassandane::Util::Log;
use Cassandane::Util::Wait;
use Cassandane::Mboxname;
use Cassandane::Config;
use Cassandane::Service;
use Cassandane::ServiceFactory;
use Cassandane::GenericDaemon;
use Cassandane::MasterStart;
use Cassandane::MasterEvent;
use Cassandane::Cassini;
use Cassandane::PortManager;
use Cassandane::Net::SMTPServer;
use Cassandane::BuildInfo;
require Cyrus::DList;

my $__cached_rootdir;
my $stamp;
my $next_unique = 1;

sub new
{
    my $class = shift;
    my %params = @_;

    my $cassini = Cassandane::Cassini->instance();

    my $self = {
        name => undef,
        buildinfo => undef,
        basedir => undef,
        installation => 'default',
        cyrus_prefix => undef,
        cyrus_destdir => undef,
        config => Cassandane::Config->default()->clone(),
        starts => [],
        services => {},
        events => [],
        generic_daemons => {},
        re_use_dir => 0,
        setup_mailbox => 1,
        persistent => 0,
        authdaemon => 1,
        _children => {},
        _stopped => 0,
        description => 'unknown',
        _shutdowncallbacks => [],
        _started => 0,
        _pwcheck => $cassini->val('cassandane', 'pwcheck', 'alwaystrue'),
    };

    $self->{name} = $params{name}
        if defined $params{name};
    $self->{basedir} = $params{basedir}
        if defined $params{basedir};
    $self->{installation} = $params{installation}
        if defined $params{installation};
    $self->{cyrus_prefix} = $cassini->val("cyrus $self->{installation}",
                                          'prefix', '/usr/cyrus');
    $self->{cyrus_prefix} = $params{cyrus_prefix}
        if defined $params{cyrus_prefix};
    $self->{cyrus_destdir} = $cassini->val("cyrus $self->{installation}",
                                          'destdir', '');
    $self->{cyrus_destdir} = $params{cyrus_destdir}
        if defined $params{cyrus_destdir};
    $self->{config} = $params{config}->clone()
        if defined $params{config};
    $self->{re_use_dir} = $params{re_use_dir}
        if defined $params{re_use_dir};
    $self->{setup_mailbox} = $params{setup_mailbox}
        if defined $params{setup_mailbox};
    $self->{persistent} = $params{persistent}
        if defined $params{persistent};
    $self->{authdaemon} = $params{authdaemon}
        if defined $params{authdaemon};
    $self->{description} = $params{description}
        if defined $params{description};
    $self->{pwcheck} = $params{pwcheck}
        if defined $params{pwcheck};

    # XXX - get testcase name from caller, to apply even finer
    # configuration from cassini ?
    return bless $self, $class;
}

# Class method! Need to be able to interrogate the Cyrus version
# being tested without actually instantiating a Cassandane::Instance.
# This also means we have to do a few things here the direct way,
# rather than using helper methods...
my %cached_version = ();
my %cached_sversion = ();
sub get_version
{
    my ($class, $installation) = @_;
    $installation = 'default' if not defined $installation;

    if (exists $cached_version{$installation}) {
        return @{$cached_version{$installation}} if wantarray;
        return $cached_sversion{$installation};
    }

    my $cassini = Cassandane::Cassini->instance();

    my $cyrus_prefix = $cassini->val("cyrus $installation",
                                     'prefix', '/usr/cyrus');
    my $cyrus_destdir = $cassini->val("cyrus $installation",
                                      'destdir', '');

    my $cyrus_master;
    foreach my $d (qw( bin sbin libexec libexec/cyrus-imapd lib cyrus/bin ))
    {
        my $try = "$cyrus_destdir$cyrus_prefix/$d/master";
        if (-x $try) {
            $cyrus_master = $try;
            last;
        }
    }

    die "unable to locate master binary" if not defined $cyrus_master;

    my $version;
    {
        open my $fh, '-|', "$cyrus_master -V"
            or die "unable to execute '$cyrus_master -V': $!";
        local $/;
        $version = <$fh>;
        close $fh;
    }

    if (not $version) {
        # Cyrus version might be too old for 'master -V'
        # Try to squirrel a version out of libcyrus pkgconfig file
        open my $fh, '<', "$cyrus_destdir$cyrus_prefix/lib/pkgconfig/libcyrus.pc";
        while (<$fh>) {
            $version = $_ if m/^Version:/;
        }
        close $fh;
    }

    #cyrus-imapd 3.0.0-beta3-114-g5fa1dbc-dirty
    if ($version =~ m/^cyrus-imapd (\d+)\.(\d+).(\d+)(?:-(.*))?$/) {
        my ($maj, $min, $rev, $extra) = ($1, $2, $3, $4);
        my $pluscommits = 0;
        if (defined $extra && $extra =~ m/(\d+)-g[a-fA-F0-9]+(?:-dirty)?$/) {
            $pluscommits = $1;
        }
        $cached_version{$installation} = [ 0 + $maj,
                                           0 + $min,
                                           0 + $rev,
                                           0 + $pluscommits,
                                           $extra ];
    }
    elsif ($version =~ m/^Version: (\d+)\.(\d+).(\d+)(?:-(.*))?$/) {
        my ($maj, $min, $rev, $extra) = ($1, $2, $3, $4);
        my $pluscommits;
        if ($extra =~ m/(\d+)-g[a-fA-F0-9]+(?:-dirty)?$/) {
            $pluscommits = $1;
        }
        $cached_version{$installation} = [ 0 + $maj,
                                           0 + $min,
                                           0 + $rev,
                                           0 + $pluscommits,
                                           $extra ];
    }
    else {
        $cached_version{$installation} = [0, 0, 0, 0, q{}];
    }

    $cached_sversion{$installation} = join q{.},
                                           @{$cached_version{$installation}}[0..2];
    $cached_sversion{$installation} .= "-$cached_version{$installation}->[4]"
        if $cached_version{$installation}->[4];

    return @{$cached_version{$installation}} if wantarray;
    return $cached_sversion{$installation};
}

sub _rootdir
{
    if (!defined $__cached_rootdir)
    {
        my $cassini = Cassandane::Cassini->instance();
        $__cached_rootdir =
            $cassini->val('cassandane', 'rootdir', '/var/tmp/cass');
    }
    return $__cached_rootdir;
}

sub _make_instance_info
{
    my ($name, $basedir) = @_;

    die "Need either a name or a basename"
        if !defined $name && !defined $basedir;
    $name ||= basename($basedir);
    $basedir ||= _rootdir() . '/' . $name;

    my $sb = stat($basedir);
    die "Cannot stat $basedir: $!" if !defined $sb && $! != ENOENT;

    return {
        name => $name,
        basedir => $basedir,
        ctime => ($sb ? $sb->ctime : undef),
    };
}

sub _make_unique_instance_info
{
    if (!defined $stamp)
    {
        $stamp = to_iso8601(DateTime->now);
        $stamp =~ s/.*T(\d+)Z/$1/;

        my $workerid = $ENV{TEST_UNIT_WORKER_ID};
        die "Invalid TEST_UNIT_WORKER_ID - code not run in Worker context"
            if (defined($workerid) && $workerid eq 'invalid');
        $stamp .= sprintf("%02X", $workerid) if defined $workerid;
    }

    my $rootdir = _rootdir();

    my $name;
    my $basedir;
    for (;;)
    {
        $name = sprintf("%s%02X", $stamp, $next_unique);
        $next_unique++;
        $basedir = "$rootdir/$name";
        last if mkdir($basedir);
        die "Cannot create $basedir: $!" if ($! != EEXIST);
    }
    return _make_instance_info($name, $basedir);
}

sub list
{
    my $rootdir = _rootdir();
    opendir ROOT, $rootdir
        or die "Cannot open $rootdir for reading: $!";
    my @instances;
    while ($_ = readdir(ROOT))
    {
        next unless m/^[0-9]+[A-Z]?$/;
        push(@instances, _make_instance_info($_));
    }
    closedir ROOT;
    return @instances;
}

sub exists
{
    my ($name) = @_;
    return if ( ! -d _rootdir() . '/' . $name );
    return _make_instance_info($name);
}

sub _init_basedir_and_name
{
    my ($self) = @_;

    my $info;
    my $which = (defined $self->{name} ? 1 : 0) |
                (defined $self->{basedir} ? 2 : 0);
    if ($which == 0)
    {
        # have neither name nor basedir
        # usual first time case for test instances
        $info = _make_unique_instance_info();
    }
    else
    {
        # have name but not basedir
        # usual first time case for start-instance.pl
        # or basedir but not name, which doesn't happen
        $info = _make_instance_info($self->{name}, $self->{basedir});
    }
    $self->{name} = $info->{name};
    $self->{basedir} = $info->{basedir};
}

sub get_basedir
{
    my ($self) = @_;

    return $self->{basedir} if $self->{basedir};

    $self->_init_basedir_and_name();

    return $self->{basedir};
}

# Remove on-disk traces of any previous instances
sub cleanup_leftovers
{
    my $rootdir = _rootdir();

    return if (!-d $rootdir);
    opendir ROOT, $rootdir
        or die "Cannot open directory $rootdir for reading: $!";
    my @dirs;
    while (my $e = readdir(ROOT))
    {
        push(@dirs, $e) if ($e =~ m/^[0-9]{6}([A-Z]|)[0-9]{1,}$/);
    }
    closedir ROOT;

    map
    {
        xlog "Cleaning up old basedir $rootdir/$_";
        rmtree "$rootdir/$_";
    } @dirs;
}

sub add_service
{
    my ($self, %params) = @_;

    my $name = $params{name};
    die "Missing parameter 'name'"
        unless defined $name;
    die "Already have a service named \"$name\""
        if defined $self->{services}->{$name};

    # Add a hardcoded recover START if we're doing an actual IMAP test.
    if ($name =~ m/imap/)
    {
        if (!grep { $_->{name} eq 'recover'; } @{$self->{starts}})
        {
            $self->add_start(name => 'recover',
                             argv => [ qw(ctl_cyrusdb -r) ]);
        }
    }

    my $srv = Cassandane::ServiceFactory->create(%params);
    $self->{services}->{$name} = $srv;
    $srv->set_config($self->{config});
    return $srv;
}

sub add_services
{
    my ($self, @names) = @_;
    map { $self->add_service(name => $_); } @names;
}

sub get_service
{
    my ($self, $name) = @_;
    return $self->{services}->{$name};
}

sub remove_service
{
    my ($self, $name) = @_;
    delete $self->{services}->{$name};
}

sub add_start
{
    my ($self, %params) = @_;
    push(@{$self->{starts}}, Cassandane::MasterStart->new(%params));
}

sub add_event
{
    my ($self, %params) = @_;
    push(@{$self->{events}}, Cassandane::MasterEvent->new(%params));
}

sub add_generic_daemon
{
    my ($self, %params) = @_;

    my $name = delete $params{name};
    die "Missing parameter 'name'"
        unless defined $name;
    die "Already have a generic daemon named \"$name\""
        if defined $self->{generic_daemons}->{$name};

    my $daemon = Cassandane::GenericDaemon->new(
            name => $name,
            config => $self->{config},
            %params
    );

    $self->{generic_daemons}->{$name} = $daemon;
    return $daemon;
}

sub set_config
{
    my ($self, $conf) = @_;

    $self->{config} = $conf;
    map { $_->set_config($conf); } (values %{$self->{services}},
                                    values %{$self->{generic_daemons}});
}

sub _find_binary
{
    my ($self, $name) = @_;

    my $cassini = Cassandane::Cassini->instance();
    my $name_override = $cassini->val("cyrus $self->{installation}", $name);
    $name = $name_override if defined $name_override;

    return $name if $name =~ m/^\//;

    my $base = $self->{cyrus_destdir} . $self->{cyrus_prefix};
    foreach (qw( bin sbin libexec libexec/cyrus-imapd lib cyrus/bin ))
    {
        my $dir = "$base/$_";
        if (opendir my $dh, $dir)
        {
            if (grep { $_ eq $name } readdir $dh) {
                xlog "Found binary $name in $dir";
                closedir $dh;
                return "$dir/$name";
            }
            closedir $dh;
        }
        else
        {
            xlog "Couldn't opendir $dir: $!" if $! != ENOENT;
            next;
        }
    }

    die "Couldn't locate $name under $base";
}

sub _binary
{
    my ($self, $name) = @_;

    my @cmd;
    my $valground = 0;

    my $cassini = Cassandane::Cassini->instance();

    if ($cassini->bool_val('valgrind', 'enabled') &&
        !($name =~ m/\.pl$/) &&
        !($name =~ m/^\//))
    {
        my $arguments = '-q --tool=memcheck --leak-check=full --run-libc-freeres=no';
        my $valgrind_logdir = $self->{basedir} . '/vglogs';
        my $valgrind_suppressions =
            abs_path($cassini->val('valgrind', 'suppression', 'vg.supp'));
        mkpath $valgrind_logdir
            unless ( -d $valgrind_logdir );
        push(@cmd,
            $cassini->val('valgrind', 'binary', '/usr/bin/valgrind'),
            "--log-file=$valgrind_logdir/$name.%p",
            "--suppressions=$valgrind_suppressions",
            "--gen-suppressions=all",
            split(/\s+/, $cassini->val('valgrind', 'arguments', $arguments))
        );
        $valground = 1;
    }

    my $bin = $self->_find_binary($name);
    push(@cmd, $bin);

    if (!$valground && $cassini->bool_val('gdb', $name))
    {
        xlog "Will run binary $name under gdb due to cassandane.ini";
        xlog "Look in syslog for helpful instructions from gdbtramp";
        push(@cmd, '-D');
    }

    return @cmd;
}

sub _imapd_conf
{
    my ($self) = @_;

    return $self->{basedir} . '/conf/imapd.conf';
}

sub _master_conf
{
    my ($self) = @_;

    return $self->{basedir} . '/conf/cyrus.conf';
}

sub _pid_file
{
    my ($self, $name) = @_;

    $name ||= 'master';

    return $self->{basedir} . "/run/$name.pid";
}

sub _list_pid_files
{
    my ($self) = @_;

    my $rundir = $self->{basedir} . "/run";
    opendir(RUNDIR, $rundir)
        or die "Cannot open run directory $rundir: $!";

    my @pidfiles;
    while ($_ = readdir(RUNDIR))
    {
        my ($name) = m/^([^.].*)\.pid$/;
        push(@pidfiles, $name) if defined $name;
    }

    closedir(RUNDIR);

    @pidfiles = sort { $a cmp $b } @pidfiles;
    @pidfiles = ( 'master', grep { $_ ne 'master' } @pidfiles );

    return @pidfiles;
}

sub _build_skeleton
{
    my ($self) = @_;

    my @subdirs =
    (
        'conf',
        'conf/cores',
        'conf/db',
        'conf/sieve',
        'conf/socket',
        'conf/proc',
        'conf/log',
        'conf/log/admin',
        'conf/log/cassandane',
        'conf/log/user2',
        'conf/log/foo',
        'conf/log/postman',
        'conf/log/repluser',
        'conf/log/smtpclient.sendmail',
        'conf/log/smtpclient.host',
        'lock',
        'data',
        'meta',
        'run',
        'tmp',
    );
    foreach my $sd (@subdirs)
    {
        my $d = $self->{basedir} . '/' . $sd;
        mkpath $d
            or die "Cannot make path $d: $!";
    }
}

sub _generate_imapd_conf
{
    my ($self) = @_;

    my ($cyrus_major_version, $cyrus_minor_version) =
        Cassandane::Instance->get_version($self->{installation});

    $self->{config}->set_variables(
        name => $self->{name},
        basedir => $self->{basedir},
        cyrus_prefix => $self->{cyrus_prefix},
        prefix => getcwd(),
    );
    $self->{config}->set(
        sasl_pwcheck_method => 'saslauthd',
        sasl_saslauthd_path => "$self->{basedir}/run/mux",
        notifysocket => "dlist:$self->{basedir}/run/notify",
        event_notifier => 'pusher',
    );
    if ($cyrus_major_version >= 3) {
        $self->{config}->set(
            imipnotifier => 'imip',
            event_groups => 'mailbox message flags calendar',
        );

        if ($cyrus_major_version > 3 || $cyrus_minor_version >= 1) {
            $self->{config}->set(
                smtp_backend => 'host',
                smtp_host => $self->{smtphost},
            );
        }
    }
    else {
        $self->{config}->set(
            event_groups => 'mailbox message flags',
        );
    }
    if ($self->{buildinfo}->get('search', 'xapian')) {
        my %xapian_defaults = (
            search_engine => 'xapian',
            search_index_headers => 'no',
            search_batchsize => '8192',
            defaultsearchtier => 't1',
            't1searchpartition-default' => "$self->{basedir}/search",
            't2searchpartition-default' => "$self->{basedir}/search2",
        );
        while (my ($k, $v) = each %xapian_defaults) {
            if (not defined $self->{config}->get($k)) {
                $self->{config}->set($k => $v);
            }
        }
    }
    $self->{config}->generate($self->_imapd_conf());
}

sub _emit_master_entry
{
    my ($self, $entry) = @_;

    my $params = $entry->master_params();
    my $name = delete $params->{name};

    # Convert ->{argv} to ->{cmd}
    my $argv = delete $params->{argv};
    die "No argv argument"
        unless defined $argv;
    # do not alter original argv
    my @args = @$argv;
    my $bin = shift @args;
    $params->{cmd} = join(' ',
        $self->_binary($bin),
        '-C', $self->_imapd_conf(),
        @args
    );

    print MASTER "    $name";
    while (my ($k, $v) = each %$params)
    {
        $v = "\"$v\""
            if ($v =~ m/\s/);
        print MASTER " $k=$v";
    }
    print MASTER "\n";
}

sub _generate_master_conf
{
    my ($self) = @_;

    my $filename = $self->_master_conf();
    my $conf = $self->_imapd_conf();
    open MASTER,'>',$filename
        or die "Cannot open $filename for writing: $!";

    if (scalar @{$self->{starts}})
    {
        print MASTER "START {\n";
        map { $self->_emit_master_entry($_); } @{$self->{starts}};
        print MASTER "}\n";
    }

    if (scalar %{$self->{services}})
    {
        print MASTER "SERVICES {\n";
        map { $self->_emit_master_entry($_); } values %{$self->{services}};
        print MASTER "}\n";
    }

    if (scalar @{$self->{events}})
    {
        print MASTER "EVENTS {\n";
        map { $self->_emit_master_entry($_); } @{$self->{events}};
        print MASTER "}\n";
    }

    # $self->{generic_daemons} is daemons *not* managed by master

    close MASTER;
}

sub _add_services_from_cyrus_conf
{
    my ($self) = @_;

    my $filename = $self->_master_conf();
    open MASTER,'<',$filename
        or die "Cannot open $filename for reading: $!";

    my $in;
    while (<MASTER>)
    {
        chomp;
        s/\s*#.*//;             # strip comments
        next if m/^\s*$/;       # skip empty lines
        my ($m) = m/^(START|SERVICES|EVENTS)\s*{/;
        if ($m)
        {
            $in = $m;
            next;
        }
        if ($in && m/^\s*}\s*$/)
        {
            $in = undef;
            next;
        }
        next if !defined $in;

        my ($name, $rem) = m/^\s*([a-zA-Z0-9]+)\s+(.*)$/;
        $_ = $rem;
        my %params;
        while (length $_)
        {
            my ($k, $rem2) = m/^([a-zA-Z0-9]+)=(.*)/;
            die "Bad parameter name" if !defined $k;
            $_ = $rem2;

            my ($v, $rem3) = m/^"([^"]*)"(.*)/;
            if (!defined $v)
            {
                ($v, $rem3) = m/^(\S*)(.*)/;
            }
            die "Bad parameter value" if !defined $v;
            $_ = $rem3;

            if ($k eq 'listen')
            {
                my $aa = Cassandane::GenericDaemon::parse_address($v);
                $params{host} = $aa->{host};
                $params{port} = $aa->{port};
            }
            elsif ($k eq 'cmd')
            {
                $params{argv} = [ split(/\s+/, $v) ];
            }
            else
            {
                $params{$k} = $v;
            }
            s/^\s+//;
        }
        if ($in eq 'SERVICES')
        {
            $self->add_service(name => $name, %params);
        }
    }

    close MASTER;
}

sub _fix_ownership
{
    my ($self, $path) = @_;

    $path ||= $self->{basedir};

    return if geteuid() != 0;
    my $uid = getpwnam('cyrus');
    my $gid = getgrnam('root');

    find(sub { chown($uid, $gid, $File::Find::name) }, $path);
}

sub _read_pid_file
{
    my ($self, $name) = @_;
    my $file = $self->_pid_file($name);
    my $pid;

    return undef if ( ! -f $file );

    open PID,'<',$file
        or return undef;
    while(<PID>)
    {
        chomp;
        ($pid) = m/^(\d+)$/;
        last;
    }
    close PID;

    return undef unless defined $pid;
    return undef unless $pid > 1;
    return undef unless kill(0, $pid) > 0;
    return $pid;
}

sub _start_master
{
    my ($self) = @_;

    # First check that nothing is listening on any of the ports
    # we expect to be able to use.  That would indicate a failure
    # of test containment - i.e. we failed to shut something down
    # earlier.  Or it might indicate that someone is trying to run
    # a second set of Cassandane tests on this machine, which is
    # also going to fail miserably.  In any case we want to know.
    foreach my $srv (values %{$self->{services}},
                     values %{$self->{generic_daemons}})
    {
        die "Some process is already listening on " . $srv->address()
            if $srv->is_listening();
    }

    # Now start the master process.
    my @cmd =
    (
        'master',
        # The following is added automatically by _fork_command:
        # '-C', $self->_imapd_conf(),
        '-l', '255',
        '-p', $self->_pid_file(),
        '-d',
        '-M', $self->_master_conf(),
    );
    if (get_verbose) {
        my $logfile = $self->{basedir} . '/conf/master.log';
        xlog "_start_master: logging to $logfile";
        push(@cmd, '-L', $logfile);
    }
    unlink $self->_pid_file();
    # Start master daemon
    $self->run_command({ cyrus => 1 }, @cmd);

    # wait until the pidfile exists and contains a PID
    # that we can verify is still alive.
    xlog "_start_master: waiting for PID file";
    timed_wait(sub { $self->_read_pid_file() },
                description => "the master PID file to exist");
    xlog "_start_master: PID file present and correct";

    # Start any other defined daemons
    foreach my $daemon (values %{$self->{generic_daemons}})
    {
        $self->run_command({ cyrus => 0 }, $daemon->get_argv());
    }

    # Wait until all the defined services are reported as listening.
    # That doesn't mean they're ready to use but it means that at least
    # a client will be able to connect(), although the first response
    # might be a bit slow.
    xlog "_start_master: PID waiting for services";
    foreach my $srv (values %{$self->{services}},
                     values %{$self->{generic_daemons}})
    {
        timed_wait(sub
                {
                    $self->is_running()
                        or die "Master no longer running";
                    $srv->is_listening();
                },
                description => $srv->address() . " to be in LISTEN state");
    }
    xlog "_start_master: all services listening";
}

sub _start_notifyd
{
    my ($self) = @_;

    my $basedir = $self->{basedir};

    my $notifypid = fork();
    unless ($notifypid) {
        $SIG{TERM} = sub { die "killed" };

        POSIX::close( $_ ) for 3 .. 1024; ## Arbitrary upper bound

        # child;
        $0 = "cassandane notifyd: $basedir";
        notifyd("$basedir/run");
        exit 0;
    }

    xlog "started notifyd for $basedir as $notifypid";
    push @{$self->{_shutdowncallbacks}}, sub {
        my $self = shift;
        xlog "killing notifyd $notifypid";
        kill(15, $notifypid);
        waitpid($notifypid, 0);
    };
}

#
# Create a user, with a home folder
#
# Argument 'user' may be of the form 'user' or 'user@domain'.
# Following that are optional named parameters
#
#   subdirs         array of strings, lists folders
#                   to be created, relative to the new
#                   home folder
#
# Returns void, or dies if something went wrong
#
sub create_user
{
    my ($self, $user, %params) = @_;

    my $mb = Cassandane::Mboxname->new(config => $self->{config}, username => $user);

    xlog "create user $user";

    my $srv = $self->get_service('imap');
    return
        unless defined $srv;

    my $adminstore = $srv->create_store(username => 'admin');
    my $adminclient = $adminstore->get_client();

    my @mboxes = ( $mb->to_external() );
    map { push(@mboxes, $mb->make_child($_)->to_external()); } @{$params{subdirs}}
        if ($params{subdirs});

    foreach my $mb (@mboxes)
    {
        $adminclient->create($mb)
            or die "Cannot create $mb: $@";
        $adminclient->setacl($mb, admin => 'lrswipkxtecdan')
            or die "Cannot setacl for $mb: $@";
        $adminclient->setacl($mb, $user => 'lrswipkxtecdn')
            or die "Cannot setacl for $mb: $@";
        $adminclient->setacl($mb, anyone => 'p')
            or die "Cannot setacl for $mb: $@";
    }
}

sub set_smtpd {
    my ($self, $data) = @_;
    my $basedir = $self->{basedir};
    if ($data) {
        open(FH, ">$basedir/conf/smtpd.json");
        print FH encode_json($data);
        close(FH);
    }
    else {
        unlink("$basedir/conf/smtpd.json");
    }
}

sub _start_smtpd {
    my ($self) = @_;

    my $basedir = $self->{basedir};

    my $host = 'localhost';

    my $port = Cassandane::PortManager::alloc();

    my $smtppid = fork();
    unless ($smtppid) {
        # Child process.
        $SIG{TERM} = sub { die "killed" };

        POSIX::close( $_ ) for 3 .. 1024; ## Arbitrary upper bound

        $0 = "cassandane smtpd: $basedir";

        my $smtpd = Cassandane::Net::SMTPServer->new({
            cass_verbose => 1,
            xmtp_personality => 'smtp',
            host => $host,
            port => $port,
            max_servers => 3, # default is 50, yikes
            control_file => "$basedir/conf/smtpd.json",
        });
        $smtpd->run() or die;
        exit 0; # Never reached
    }

    # Parent process.
    $self->{smtphost} = $host . ':' . $port;

    # XXX give the child a moment to actually start up before we start
    # XXX assuming it has
    sleep 1;

    xlog "started smtpd as $smtppid";
    push @{$self->{_shutdowncallbacks}}, sub {
        my $self = shift;
        xlog "killing smtpd $smtppid";
        kill(15, $smtppid);
        waitpid($smtppid, 0);
    }
}

sub start_httpd {
    my ($self, $handler, $port) = @_;

    my $basedir = $self->{basedir};

    my $host = 'localhost';
    $port ||= Cassandane::PortManager::alloc();

    my $httpdpid = fork();
    unless ($httpdpid) {
        # Child process.
        $SIG{TERM} = sub { exit 0; };

        POSIX::close( $_ ) for 3 .. 1024; ## Arbitrary upper bound

        $0 = "cassandane httpd: $basedir";

        my $httpd = HTTP::Daemon->new(
            LocalAddr => $host,
            LocalPort => $port,
            ReuseAddr => 1, # Reuse ports left in TIME_WAIT
        ) || die;
        while (my $conn = $httpd->accept) {
            while (my $req = $conn->get_request) {
                $handler->($conn, $req);
            }
            $conn->close;
            undef($conn);
        }

        exit 0; # Never reached
    }

    # Parent process.
    $self->{httpdhost} = $host . ':' . $port;

    xlog "started httpd as $httpdpid";
    push @{$self->{_shutdowncallbacks}}, sub {
        my $self = shift;
        xlog "killing httpd $httpdpid";
        kill(15, $httpdpid);
        waitpid($httpdpid, 0);
    };

    return $port;
}

sub start
{
    my ($self) = @_;

    my $created = 0;

    $self->_init_basedir_and_name();
    xlog "start $self->{description}: basedir $self->{basedir}";

    my $syslog_start = 0;
    if (-e 'utils/syslog.so') { # XXX check a bit harder?
        $self->{syslog_fname} = "$self->{basedir}/conf/log/syslog";
        $self->{have_syslog_replacement} = 1;

        # if the syslog file already exists, remember how large it is
        # so we can seek past existing content without missing the
        # startup content!
        $syslog_start = -s $self->{syslog_fname} if -e $self->{syslog_fname};
    }
    else {
        xlog "utils/syslog.so not found (do you need to run 'make'?)";
        xlog "tests will not examine syslog output";
        $self->{have_syslog_replacement} = 0;
    }


    # Start SMTP server before generating imapd config, we need to
    # to set smtp_host to the auto-assigned TCP port it listens on.
    $self->_start_smtpd();

    # arrange for fakesaslauthd to be started by master
    # XXX make this run as a DAEMON rather than a START
    my $fakesaslauthd_socket = "$self->{basedir}/run/mux";
    if ($self->{authdaemon}) {
        $self->add_start(
            name => 'fakesaslauthd',
            argv => [
                abs_path('utils/fakesaslauthd'),
                '-p', $fakesaslauthd_socket,
            ],
        );
    }

    if (!$self->{re_use_dir} || ! -d $self->{basedir})
    {
        $created = 1;
        rmtree $self->{basedir};
        $self->_build_skeleton();
        # TODO: system("echo 1 >/proc/sys/kernel/core_uses_pid");
        # TODO: system("echo 1 >/proc/sys/fs/suid_dumpable");
        $self->{buildinfo} = Cassandane::BuildInfo->new($self->{cyrus_destdir},
                                                        $self->{cyrus_prefix});
        $self->_generate_imapd_conf();
        $self->_generate_master_conf();
        $self->_fix_ownership();
    }
    elsif (!scalar $self->{services})
    {
        $self->_add_services_from_cyrus_conf();
    }
    $self->_start_notifyd();
    $self->_uncompress_berkeley_crud();
    $self->_start_master();
    $self->{_stopped} = 0;
    $self->{_started} = 1;

    if ($self->{have_syslog_replacement}) {
        $self->{_syslogfh} = IO::File->new($self->{syslog_fname}, 'r')
            || die "can't open file $self->{syslog_fname}";
        $self->{_syslogfh}->seek($syslog_start, 0);
        $self->{_syslogfh}->blocking(0);
    }

    # give fakesaslauthd a moment (but not more than 2s) to set up its
    # socket before anything starts trying to connect to services
    if ($self->{authdaemon}) {
        my $tries = 0;
        while (not -S $fakesaslauthd_socket && $tries < 2_000_000) {
            $tries += usleep(10_000); # 10ms as us
        }
        die "fakesaslauthd socket $fakesaslauthd_socket not ready after 2s!"
            if not -S $fakesaslauthd_socket;
    }

    if ($created && $self->{setup_mailbox})
    {
        $self->create_user("cassandane");
    }

    xlog "started $self->{description}: cyrus version "
        . Cassandane::Instance->get_version($self->{installation});
}

sub _compress_berkeley_crud
{
    my ($self) = @_;

    my @files;
    my $dbdir = $self->{basedir} . "/conf/db";
    if ( -d $dbdir )
    {
        opendir DBDIR, $dbdir
            or die "Cannot open directory $dbdir: $!";
        while (my $e = readdir DBDIR)
        {
            push(@files, "$dbdir/$e")
                if ($e =~ m/^__db\.\d+$/);
        }
        closedir DBDIR;
    }

    if (scalar @files)
    {
        xlog "Compressing Berkeley environment files: " . join(' ', @files);
        system('/bin/bzip2', @files);
    }
}

sub _uncompress_berkeley_crud
{
    my ($self) = @_;

    my @files;
    my $dbdir = $self->{basedir} . "/conf/db";
    if ( -d $dbdir )
    {
        opendir DBDIR, $dbdir
            or die "Cannot open directory $dbdir: $!";
        while (my $e = readdir DBDIR)
        {
            push(@files, "$dbdir/$e")
                if ($e =~ m/^__db\.\d+\.bz2$/);
        }
        closedir DBDIR;
    }

    if (scalar @files)
    {
        xlog "Uncompressing Berkeley environment files: " . join(' ', @files);
        system('/bin/bunzip2', @files);
    }
}

sub _check_valgrind_logs
{
    my ($self) = @_;

    return unless Cassandane::Cassini->instance()->bool_val('valgrind', 'enabled');

    my $valgrind_logdir = $self->{basedir} . '/vglogs';
    my $nerrs = 0;

    return unless -d $valgrind_logdir;
    opendir VGLOGS, $valgrind_logdir
        or die "Cannot open directory $valgrind_logdir for reading: $!";
    my @nzlogs;
    while ($_ = readdir VGLOGS)
    {
        next if m/^\./;
        next if m/\.core\./;
        my $log = "$valgrind_logdir/$_";
        next if -z $log;
        push(@nzlogs, $_);

        xlog "Valgrind errors from file $log";
        open VG, "<$log"
            or die "Cannot open Valgrind log $log for reading: $!";
        while (<VG>) {
            chomp;
            xlog "$_";
        }
        close VG;

    }
    closedir VGLOGS;

    die "Found Valgrind errors, see log for details"
        if scalar @nzlogs;
}

# The 'file' program seems to consistently misreport cores
# so we apply a heuristic that seems to work
sub _detect_core_program
{
    my ($core) = @_;
    my $lines = 0;
    my $prog;

    open STRINGS, '-|', ('strings', '-a', $core)
        or die "Cannot run strings on $core: $!";
    while (<STRINGS>)
    {
        chomp;
        if (m/\/bin\//)
        {
            $prog = $_;
            last;
        }
        $lines++;
        last if ($lines > 10);
    }
    close STRINGS;

    return $prog;
}

sub _check_cores
{
    my ($self) = @_;

    my $coredir = $self->{basedir} . '/conf/cores';
    my $ncores = 0;

    return unless -d $coredir;
    opendir CORES, $coredir
        or die "Cannot open directory $coredir for reading: $!";
    while ($_ = readdir CORES)
    {
        next if m/^\./;
        next unless m/^core(\.\d+)?$/;
        my $core = "$coredir/$_";
        next if -z $core;
        chmod(0644, $core);
        $ncores++;

        my $prog = _detect_core_program($core);

        xlog "Found core file $core";
        xlog "   from program $prog" if defined $prog;
    }
    closedir CORES;

    die "Core files found in $coredir" if $ncores;
}

sub _check_syslog
{
    my ($self) = @_;

    my @lines = $self->getsyslog();

    my @errors = grep { m/ERROR|Unknown code ____/ } @lines;

    @errors = grep { not m/DBERROR.*skipstamp/ } @errors;

    $self->xlog("syslog error: $_") for @errors;

    die "Errors found in syslog" if @errors;
}

# Stop a given PID.  Returns 1 if the process died
# gracefully (i.e. soon after receiving SIGTERM)
# or wasn't even running beforehand.
sub _stop_pid
{
    my ($pid, $reaper) = @_;

    # Try to be nice, but leave open the option of not being nice should
    # that be necessary.  The signals we send are:
    #
    # SIGTERM - The standard Cyrus graceful shutdown signal, should
    #           be handled and propagated by master.
    # SIGILL - Not handled by master; kernel's default action is to
    #          dump a core.  We use this to try to get a core when
    #          something is wrong with master.
    # SIGKILL - Hmm, something went wrong with our cunning SIGILL plan,
    #           let's take off and nuke it from orbit.  We just don't
    #           want to leave processes around cluttering up the place.
    #
    my @sigs = ( SIGTERM, SIGILL, SIGKILL );
    my %signame = (
        SIGTERM, "TERM",
        SIGILL,  "ILL",
        SIGKILL, "KILL",
    );
    my $r = 1;

    foreach my $sig (@sigs)
    {
        xlog "_stop_pid: sending signal $signame{$sig} to $pid";
        kill($sig, $pid) or xlog "Can't send signal $signame{$sig} to pid $pid: $!";
        eval {
            timed_wait(sub {
                eval { $reaper->() if (defined $reaper) };
                return (kill(0, $pid) == 0);
            });
        };
        last unless $@;
        # Timed out -- No More Mr Nice Guy
        xlog "_stop_pid: failed to shut down pid $pid with signal $signame{$sig}";
        $r = 0;
    }
    return $r;
}

sub send_sighup
{
    my ($self) = @_;

    return if (!$self->{_started});
    return if ($self->{_stopped});
    xlog "sighup";

    my $pid = $self->_read_pid_file('master') or return;
    kill(SIGHUP, $pid) or die "Can't send signal SIGHUP to pid $pid: $!";
    return 1;
}

sub stop
{
    my ($self) = @_;

    $self->_init_basedir_and_name();

    return if ($self->{_stopped});
    $self->{_stopped} = 1;

    xlog "stop $self->{description}: basedir $self->{basedir}";

    foreach my $name ($self->_list_pid_files())
    {
        my $pid = $self->_read_pid_file($name);
        next if (!defined $pid);
        _stop_pid($pid)
            or die "Cannot shut down $name pid $pid";
    }
    # Note: no need to reap this daemon which is not our child anymore

    foreach my $item (@{$self->{_shutdowncallbacks}}) {
        $item->($self);
    }
    $self->{_shutdowncallbacks} = [];

    $self->_compress_berkeley_crud();
    $self->_check_valgrind_logs();
    $self->_check_cores();
    $self->_check_syslog();
}

sub cleanup
{
    my ($self) = @_;

    if (Cassandane::Cassini->instance()->bool_val('cassandane', 'cleanup'))
    {
        # Remove all on-disk traces of this instance
        xlog "Cleaning up basedir " . $self->{basedir};
        rmtree $self->{basedir};
    }
}

sub DESTROY
{
    my ($self) = @_;

    if (defined $self->{basedir} &&
        !$self->{persistent} &&
        !$self->{_stopped})
    {
        # clean up any dangling master and daemon process
        foreach my $name ($self->_list_pid_files())
        {
            my $pid = $self->_read_pid_file($name);
            next if (!defined $pid);
            _stop_pid($pid);
        }

        foreach my $item (@{$self->{_shutdowncallbacks}}) {
            $item->($self);
        }
        $self->{_shutdowncallbacks} = [];
    }
}

sub is_running
{
    my ($self) = @_;

    my $pid = $self->_read_pid_file();
    return 0 unless defined $pid;
    return kill(0, $pid);
}

sub _setup_for_deliver
{
    my ($self) = @_;

    $self->add_service(name => 'lmtp',
                       argv => ['lmtpd', '-a'],
                       port => '@basedir@/conf/socket/lmtp');
}

sub deliver
{
    my ($self, $msg, %params) = @_;
    my $str = $msg->as_string();
    my @cmd = ( 'deliver' );

    my $folder = $params{folder};
    if (defined $folder)
    {
        $folder =~ s/^inbox.//i;
        push(@cmd, '-m', $folder);
    }

    my @users;
    if (defined $params{users})
    {
        push(@users, @{$params{users}});
    }
    elsif (defined $params{user})
    {
        push(@users, $params{user})
    }
    else
    {
        push(@users, 'cassandane');
    }
    push(@cmd, @users);

    my $ret = 0;

    $self->run_command({
        cyrus => 1,
        redirects => {
            stdin => \$str
        },
        handlers => {
            exited_abnormally => sub { (undef, $ret) = @_; },
        },
    }, @cmd);

    return $ret;
}

# Runs a command with the given arguments.  The first argument is an
# options hash:
#
# background  whether to start the command in the background; you need
#           to give returned arguments to reap_command afterwards
#
# cyrus     whether it is a cyrus utility; if so, instance path is
#           automatically prepended to the given command name
#
# handlers  hash of coderefs to be called when various events
#           are detected.  Default is to 'die' on any event
#           except exiting with code 0.  The events are:
#
#   exited_normally($child)
#   exited_abnormally($child, $code)
#   signaled($child, $sig)
#
# redirects  hash for I/O redirections
#     stdin     feed stdin from; handles SCALAR data or filename,
#                   /dev/null by default
#     stdout    feed stdout to; /dev/null by default (or is unmolested
#                   if xlog is in verbose mode)
#     stderr    feed stderr to; /dev/null by default (or is unmolested
#                   if xlog is in verbose mode)
#
# workingdir  path to launch the command from
#
sub run_command
{
    my ($self, @args) = @_;

    my $options = {};
    if (ref($args[0]) eq 'HASH') {
        $options = shift(@args);
    }

    my ($pid, $got_exit) = $self->_fork_command($options, @args);

    return $pid
        if ($options->{background});

    if (defined $got_exit) {
        # Child already reaped, pass it on
        $? = $got_exit;

        return $self->_handle_wait_status($pid);
    }

    return $self->reap_command($pid);
}

sub reap_command
{
    my ($self, $pid) = @_;

    # parent process...wait for child
    my $child = waitpid($pid, 0);
    # and deal with it's exit status
    return $self->_handle_wait_status($pid)
        if $child == $pid;
    return undef;
}

sub stop_command
{
    my ($self, $pid) = @_;
    _stop_pid($pid, sub { $self->reap_command($pid); } );
    $self->reap_command($pid);
}

my %default_command_handlers = (
    signaled => sub
    {
        my ($child, $sig) = @_;
        my $desc = _describe_child($child);
        die "child process $desc terminated by signal $sig";
    },
    exited_normally => sub
    {
        my ($child) = @_;
        return 0;
    },
    exited_abnormally => sub
    {
        my ($child, $code) = @_;
        my $desc = _describe_child($child);
        die "child process $desc exited with code $code";
    },
);

sub _add_child
{
    my ($self, $binary, $pid, $handlers) = @_;
    my $key = $pid;

    $handlers ||= \%default_command_handlers;

    my $child = {
        binary => $binary,
        pid => $pid,
        handlers => { %default_command_handlers, %$handlers },
    };
    $self->{_children}->{$key} = $child;
    return $child;
}

sub _describe_child
{
    my ($child) = @_;
    return "unknown" unless $child;
    return "(binary $child->{binary} pid $child->{pid})";
}

sub _cyrus_perl_search_path
{
    my ($self) = @_;
    my @inc = (
        substr($Config{installvendorlib}, length($Config{vendorprefix})),
        substr($Config{installvendorarch}, length($Config{vendorprefix})),
        substr($Config{installsitelib}, length($Config{siteprefix})),
        substr($Config{installsitearch}, length($Config{siteprefix}))
    );
    return map { $self->{cyrus_destdir} . $self->{cyrus_prefix} . $_; } @inc;
}

#
# Starts a new process to run a program.
#
# Returns launched $pid; you must call _handle_wait_status() to
#          decode $?.  Dies on errors.
#
sub _fork_command
{
    my ($self, $options, $binary, @argv) = @_;

    die "No binary specified"
        unless defined $binary;

    my %redirects;
    if (defined($options->{redirects})) {
        %redirects = %{$options->{redirects}};
    }
    # stdin is null, stdout is null or unmolested
    $redirects{stdin} = '/dev/null'
        unless(defined($redirects{stdin}));
    $redirects{stdout} = '/dev/null'
        unless(get_verbose || defined($redirects{stdout}));
    $redirects{stderr} = '/dev/null'
        unless(get_verbose || defined($redirects{stderr}));

    my @cmd = ();
    if ($options->{cyrus})
    {
        push(@cmd, $self->_binary($binary), '-C', $self->_imapd_conf());
    }
    else {
        push(@cmd, $binary);
    }
    push(@cmd, @argv);

    xlog "Running: " . join(' ', map { "\"$_\"" } @cmd);

    if (defined($redirects{stdin}) && (ref($redirects{stdin}) eq 'SCALAR'))
    {
        my $fh;
        my $data = $redirects{stdin};
        $redirects{stdin} = undef;
        # Use the fork()ing form of open()
        my $pid = open $fh,'|-';
        die "Cannot fork: $!"
            if !defined $pid;
        if ($pid)
        {
            xlog "child pid=$pid";
            # parent process
            $self->_add_child($binary, $pid, $options->{handlers});
            print $fh ${$data};
            close ($fh);
            return ($pid, $?);
        }
    }
    else
    {
        # No capturing - just plain fork()
        my $pid = fork();
        die "Cannot fork: $!"
            if !defined $pid;
        if ($pid)
        {
            # parent process
            xlog "child pid=$pid";
            $self->_add_child($binary, $pid, $options->{handlers});
            return ($pid, undef);
        }
    }

    # child process

    my $cassroot = getcwd();
    $ENV{CASSANDANE_CYRUS_DESTDIR} = $self->{cyrus_destdir};
    $ENV{CASSANDANE_CYRUS_PREFIX} = $self->{cyrus_prefix};
    $ENV{CASSANDANE_PREFIX} = $cassroot;
    $ENV{CASSANDANE_BASEDIR} = $self->{basedir};
    $ENV{CASSANDANE_VERBOSE} = 1 if get_verbose();
    $ENV{PERL5LIB} = join(':', ($cassroot, $self->_cyrus_perl_search_path()));
    if ($self->{have_syslog_replacement}) {
        $ENV{CASSANDANE_SYSLOG_FNAME} = abs_path($self->{syslog_fname});
        $ENV{LD_PRELOAD} = abs_path('utils/syslog.so')
    }

#     xlog "\$PERL5LIB is"; map { xlog "    $_"; } split(/:/, $ENV{PERL5LIB});

    # Set up the runtime linker path to find the Cyrus shared libraries
    #
    # TODO: on some platforms we need lib64/ not lib/ but it's not
    # entirely clear how to detect that - we could use readelf -d
    # on an executable to discover what it thinks it's RPATH ought
    # to be, then prepend destdir to that.
    if ($self->{cyrus_destdir} ne "")
    {
        $ENV{LD_LIBRARY_PATH} = join(':', (
                $self->{cyrus_destdir} . $self->{cyrus_prefix} . "/lib",
                split(/:/, $ENV{LD_LIBRARY_PATH} || "")
        ));
    }
#     xlog "\$LD_LIBRARY_PATH is"; map { xlog "    $_"; } split(/:/, $ENV{LD_LIBRARY_PATH});

    my $cd = $options->{workingdir};
    $cd = $self->{basedir} . '/conf/cores'
        unless defined($cd);
    chdir($cd)
        or die "Cannot cd to $cd: $!";

    # ulimit -c ...
    my $cassini = Cassandane::Cassini::instance();
    my $coresizelimit = 0 + $cassini->val("cyrus $self->{installation}",
                                          'coresizelimit', '100');
    if ($coresizelimit <= 0) {
        $coresizelimit = RLIM_INFINITY;
    }
    else {
        # convert megabytes to bytes
        $coresizelimit *= (1024 * 1024);
    }
    xlog "setting core size limit to $coresizelimit";
    setrlimit(RLIMIT_CORE, $coresizelimit, $coresizelimit);

    # let's log our rlimits, might be useful for diagnosing weirdnesses
    if (get_verbose() >= 4) {
        my $limits = get_rlimits();
        foreach my $name (keys %{$limits}) {
            $limits->{$name} = [ getrlimit($limits->{$name}) ];
        }
        xlog "rlimits: " . Dumper $limits;
    }

    # TODO: do any setuid, umask, or environment futzing here

    # implement redirects
    if (defined $redirects{stdin})
    {
        open STDIN,'<',$redirects{stdin}
            or die "Cannot redirect STDIN from $redirects{stdin}: $!";
    }
    if (defined $redirects{stdout})
    {
        open STDOUT,'>',$redirects{stdout}
            or die "Cannot redirect STDOUT to $redirects{stdout}: $!";
    }
    if (defined $redirects{stderr})
    {
        open STDERR,'>',$redirects{stderr}
            or die "Cannot redirect STDERR to $redirects{stderr}: $!";
    }

    exec @cmd;
    die "Cannot run $binary: $!";
}

sub _handle_wait_status
{
    my ($self, $key) = @_;
    my $status = $?;

    my $child = delete $self->{_children}->{$key};

    if (WIFSIGNALED($status))
    {
        my $sig = WTERMSIG($status);
        return $child->{handlers}->{signaled}->($child, $sig);
    }
    elsif (WIFEXITED($status))
    {
        my $code = WEXITSTATUS($status);
        return $child->{handlers}->{exited_abnormally}->($child, $code)
            if $code != 0;
    }
    else
    {
        die "WTF? Cannot decode wait status $status";
    }
    return $child->{handlers}->{exited_normally}->($child);
}

sub describe
{
    my ($self) = @_;

    print "Cyrus instance\n";
    printf "    name: %s\n", $self->{name};
    printf "    imapd.conf: %s\n", $self->_imapd_conf();
    printf "    services:\n";
    foreach my $srv (values %{$self->{services}})
    {
        printf "        ";
        $srv->describe();
    }
    printf "    generic daemons:\n";
    foreach my $daemon (values %{$self->{generic_daemons}})
    {
        printf "        ";
        $daemon->describe();
    }
}

sub _quota_Z_file
{
    my ($self, $mboxname) = @_;
    return $self->{basedir} . '/conf/quota-sync/' . $mboxname;
}

sub quota_Z_go
{
    my ($self, $mboxname) = @_;
    $mboxname =~ s/\./\x1F/g;
    my $filename = $self->_quota_Z_file($mboxname);

    xlog "Allowing quota -Z to proceed for $mboxname";

    my $dir = dirname($filename);
    mkpath $dir
        unless ( -d $dir );

    my $fd = POSIX::creat($filename, 0600);
    POSIX::close($fd);
}

sub quota_Z_wait
{
    my ($self, $mboxname) = @_;
    $mboxname =~ s/\./\x1F/g;
    my $filename = $self->_quota_Z_file($mboxname);

    timed_wait(sub { return (! -f $filename); },
                description => "quota -Z to be finished with $mboxname");
}

#
# Unpacks file.  Handles tar, gz, and bz2.
#
sub unpackfile
{
    my ($self, $src, $dst) = @_;

    if (!defined($dst)) {
        # unpack in base directory
        $dst = $self->{basedir};
    }
    elsif ($dst !~ /^\//) {
        # unpack relatively to base directory
        $dst = $self->{basedir} . '/' . $dst;
    }
    # else: absolute path given
xlog "Path: $dst";

    my $options = {};
    my @cmd = ();

    my $file = [split(/\./, (split(/\//, $src))[-1])];
    if (grep { $_ eq 'tar' } @$file) {
        push(@cmd, 'tar', '-x', '-f', $src, '-C', $dst);
    }
    elsif ($file->[-1] eq 'gz') {
        $options->{redirects} = {
            stdout => "$dst/" . join('.', splice(@$file, 0, -1))
        };
        push(@cmd, 'gunzip', '-c', $src);
    }
    elsif ($file->[-1] eq 'bz2') {
        $options->{redirects} = {
            stdout => "$dst/" . join('.', splice(@$file, 0, -1))
        };
        push(@cmd, 'bunzip2', '-c', $src);
    }
    else {
        # we don't handle this combination
        die "Unhandled packed file $src";
    }

use Data::Dumper;
xlog "Running: " . Dumper(@cmd);
    return $self->run_command($options, @cmd);
}

sub folder_to_directory
{
    my ($self, $uniqueid) = @_;

    my $first = substr($uniqueid, 0, 1);
    my $second = substr($uniqueid, 1, 1);

    my $dir = $self->{basedir} . "/data/$first/$second/$uniqueid";
    return undef unless -d $dir;
    return $dir;
}

sub folder_to_archive_directory
{
    my ($self, $uniqueid) = @_;

    my $first = substr($uniqueid, 0, 1);
    my $second = substr($uniqueid, 1, 1);

    my $dir = $self->{basedir} . "/archive/$first/$second/$uniqueid";
    return undef unless -d $dir;
    return $dir;
}

sub notifyd
{
    my $dir = shift;

    $0 = "cassandane notifyd $dir";

    my @EVENTS;
    tcp_server("unix/", "$dir/notify", sub {
        my $fh = shift;
        my $Handle = AnyEvent::Handle->new(
            fh => $fh,
        );
        $Handle->push_read('Cyrus::DList' => 1, sub {
            my $dlist = $_[1];
            my $event = $dlist->as_perl();
            #xlog "GOT EVENT: " . encode_json($event);
            push @EVENTS, $event;
            $Handle->push_write('Cyrus::DList' => scalar(Cyrus::DList->new_kvlist("OK")), 1);
            $Handle->push_shutdown();
        });
    });

    tcp_server("unix/", "$dir/getnotify", sub {
        my $fh = shift;
        my $Handle = AnyEvent::Handle->new(
            fh => $fh,
        );
        #xlog "REPLYING EVENTS: " . scalar(@EVENTS);
        $Handle->push_write(json => \@EVENTS);
        $Handle->push_shutdown();
        @EVENTS = ();
    });

    my $cv = AnyEvent->condvar();

    $SIG{TERM} = sub { $cv->send() };

    $cv->recv();
}

sub getnotify
{
    my ($self) = @_;

    my $basedir = $self->{basedir};
    my $path = "$basedir/run/getnotify";

    my $data = eval {
        my $sock = IO::Socket::UNIX->new(
            Type => SOCK_STREAM(),
            Peer => $path,
        ) || die "Connection failed $!";
        my $line = $sock->getline();
        my $json = decode_json($line);
        if (get_verbose) {
            use Data::Dumper;
            warn "NOTIFY " . Dumper($json);
        }
        return $json;
    };
    if ($@) {
        my $data = `ls -la $basedir/run; whoami; lsof -n | grep notify`;
        xlog "Failed $@ ($data)";
    }

    return $data;
}

sub getsyslog
{
    my ($self) = @_;
    my $logname = $self->{name};
    if ($self->{_syslogfh}) {
        # hopefully unobtrusively, let busy log finish writing
        usleep(100_000); # 100ms (0.1s) as us
        my @lines = grep { m/$logname/ } $self->{_syslogfh}->getlines();
        chomp for @lines;
        return @lines;
    }
    return ();
}

sub _get_sqldb
{
    my $dbfile = shift;
    my $dbh = DBI->connect("dbi:SQLite:$dbfile", undef, undef);
    my @tables = map { s/"//gs; s/^main\.//; $_ } $dbh->tables();
    my %res;
    foreach my $table (@tables) {
        $res{$table} = $dbh->selectall_arrayref("SELECT * FROM $table", { Slice => {} });
    }
    return \%res;
}

sub getalarmdb
{
    my $self = shift;
    my $file = "$self->{basedir}/conf/caldav_alarm.sqlite3";
    return [] unless -e $file;
    my $data = _get_sqldb($file);
    return $data->{events} || die "NO EVENTS IN CALDAV ALARM DB";
}

sub getdavdb
{
    my $self = shift;
    my $user = shift;
    my $file = $self->get_conf_user_file($user, 'dav');
    return unless -e $file;
    return _get_sqldb($file);
}

sub get_sieve_script_dir
{
    my ($self, $cyrusname) = @_;

    $cyrusname //= '';

    my $sieved = "$self->{basedir}/conf/sieve";

    my ($user, $domain) = split '@', $cyrusname;

    if ($domain) {
        my $dhash = substr($domain, 0, 1);
        $sieved .= "/domain/$dhash/$domain";
    }

    if ($user ne '')
    {
        my $uhash = substr($user, 0, 1);
        $sieved .= "/$uhash/$user/";
    }
    else
    {
        # shared folder
        $sieved .= '/global/';
    }

    return $sieved;
}

sub get_conf_user_file
{
    my ($self, $cyrusname, $ext) = @_;

    my ($user, $domain) = split '@', $cyrusname;

    my $base = "$self->{basedir}/conf";
    if ($domain) {
        my $dhash = substr($domain, 0, 1);
        $base .= "/domain/$dhash/$domain";
    }

    my $uhash = substr($user, 0, 1);

    return "$base/user/$uhash/$user.$ext";
}

sub install_sieve_script
{
    my ($self, $script, %params) = @_;

    my $user = (exists $params{username} ? $params{username} : 'cassandane');
    my $name = $params{name} || 'test1';
    my $sieved = $self->get_sieve_script_dir($user);

    xlog "Installing sieve script $name in $sieved";

    -d $sieved or mkpath $sieved
        or die "Cannot make path $sieved: $!";
    die "Path does not exist: $sieved" if not -d $sieved;

    open(FH, '>', "$sieved/$name.script")
        or die "Cannot open $sieved/$name.script for writing: $!";
    print FH $script;
    close(FH);

    $self->run_command({ cyrus => 1 },
                         "sievec",
                         "$sieved/$name.script",
                         "$sieved/$name.bc");
    die "File does not exist: $sieved/$name.bc" if not -f "$sieved/$name.bc";

    -e "$sieved/defaultbc" || symlink("$name.bc", "$sieved/defaultbc")
        or die "Cannot symlink $name.bc to $sieved/defaultbc";
    die "Symlink does not exist: $sieved/defaultbc" if not -l "$sieved/defaultbc";

    xlog "Sieve script installed successfully";
}

sub install_old_mailbox
{
    my ($self, $user, $version, $dest_dir) = @_;

    my $data_file = abs_path("data/old-mailboxes/version$version.tar.gz");
    die "Old mailbox data does not exist: $data_file" if not -f $data_file;

    xlog "installing version $version mailbox for user $user";

    $self->unpackfile($data_file, $dest_dir);
#    $self->run_command({ cyrus => 1 }, 'reconstruct', '-f', "user.$user");

    xlog "installed version $version mailbox for user $user: user.$user.version$version";

    return "user.$user.version$version";
}

sub get_servername
{
    my ($self) = @_;

    return $self->{config}->get('servername');
}
1;
