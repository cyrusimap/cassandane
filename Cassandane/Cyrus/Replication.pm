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

package Cassandane::Cyrus::Replication;
use strict;
use warnings;
use Data::Dumper;
use DateTime;

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;
use Cassandane::Service;
use Cassandane::Config;

sub new
{
    my $class = shift;
    return $class->SUPER::new({ adminstore => 1, replica => 1 }, @_);
}

sub set_up
{
    my ($self) = @_;
    $self->SUPER::set_up();
}

sub tear_down
{
    my ($self) = @_;
    $self->SUPER::tear_down();
}

#
# Test replication of messages APPENDed to the master
#
sub test_append
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    my $replica_store = $self->{replica_store};

    xlog $self, "generating messages A..D";
    my %exp;
    $exp{A} = $self->make_message("Message A", store => $master_store);
    $exp{B} = $self->make_message("Message B", store => $master_store);
    $exp{C} = $self->make_message("Message C", store => $master_store);
    $exp{D} = $self->make_message("Message D", store => $master_store);

    xlog $self, "Before replication, the master should have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "Before replication, the replica should have no messages";
    $self->check_messages({}, store => $replica_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication, the master should still have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should now have all four messages";
    $self->check_messages(\%exp, store => $replica_store);
}

#
# Test replication of messages APPENDed to the master
#
sub test_splitbrain
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    my $replica_store = $self->{replica_store};

    xlog $self, "generating messages A..D";
    my %exp;
    $exp{A} = $self->make_message("Message A", store => $master_store);
    $exp{B} = $self->make_message("Message B", store => $master_store);
    $exp{C} = $self->make_message("Message C", store => $master_store);
    $exp{D} = $self->make_message("Message D", store => $master_store);

    xlog $self, "Before replication, the master should have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "Before replication, the replica should have no messages";
    $self->check_messages({}, store => $replica_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication, the master should still have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should now have all four messages";
    $self->check_messages(\%exp, store => $replica_store);

    my %mexp = %exp;
    my %rexp = %exp;

    $mexp{E} = $self->make_message("Message E", store => $master_store);
    $rexp{F} = $self->make_message("Message F", store => $replica_store);

    # uid is 5 at both ends
    $rexp{F}->set_attribute(uid => 5);

    xlog $self, "No replication, the master should have its 5 messages";
    $self->check_messages(\%mexp, store => $master_store);
    xlog $self, "No replication, the replica should have the other 5 messages";
    $self->check_messages(\%rexp, store => $replica_store);

    $self->run_replication();
    # replication will generate a couple of SYNCERRORS in syslog
    my @syslog = $self->{instance}->getsyslog();
    $self->assert_matches(qr/\bSYNCERROR: guid mismatch user.cassandane 5\b/,
                          "@syslog");
    $self->check_replication('cassandane');


    %exp = (%mexp, %rexp);
    # we could calculate 6 and 7 by sorting from GUID, but easiest is to ignore UIDs
    $exp{E}->set_attribute(uid => undef);
    $exp{F}->set_attribute(uid => undef);
    xlog $self, "After replication, the master should have all 6 messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should have all 6 messages";
    $self->check_messages(\%exp, store => $replica_store);
}

#
# Test replication of mailbox only after a rename
#
sub test_splitbrain_mailbox
    :min_version_3_1
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    my $replica_store = $self->{replica_store};

    my $mastertalk = $master_store->get_client();
    my $replicatalk = $replica_store->get_client();

    $mastertalk->create("INBOX.src-name");

    xlog $self, "run initial replication";
    $self->run_replication();
    $self->check_replication('cassandane');

    $mastertalk = $master_store->get_client();
    $mastertalk->rename("INBOX.src-name", "INBOX.dest-name");

    $self->{instance}->getsyslog();
    $self->{replica}->getsyslog();

    xlog $self, "try replicating just the mailbox by name fails due to duplicate uniqueid";
    eval { $self->run_replication(mailbox => 'user.cassandane.dest-name') };
    $self->assert_matches(qr/exited with code 1/, "$@");
    my @mastersyslog = $self->{instance}->getsyslog();
    my @replicasyslog = $self->{replica}->getsyslog();

    $self->assert(grep { m/MAILBOX received NO response: IMAP_MAILBOX_MOVED/ } @mastersyslog);
    $self->assert(grep { m/SYNCNOTICE: failed to create mailbox user\x1Fcassandane\x1Fdest-name/ } @replicasyslog);

    xlog $self, "Run a full user replication to repair";
    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "Rename again";
    $mastertalk = $master_store->get_client();
    $mastertalk->rename("INBOX.dest-name", "INBOX.foo");
    my $file = $self->{instance}->{basedir} . "/sync.log";
    open(FH, ">", $file);
    print FH "MAILBOX user\x1Fcassandane\x1Ffoo\n";
    close(FH);

    $self->{instance}->getsyslog();
    $self->{replica}->getsyslog();
    xlog $self, "Run replication from a file with just the mailbox name in it";
    $self->run_replication(inputfile => $file, rolling => 1);
    @mastersyslog = $self->{instance}->getsyslog();
    @replicasyslog = $self->{replica}->getsyslog();
    # initial failures
    $self->assert(grep { m/do_folders\(\): update failed: user\x1Fcassandane\x1Ffoo/ } @mastersyslog);
    $self->assert(grep { m/SYNCNOTICE: failed to create mailbox user\x1Fcassandane\x1Ffoo/ } @replicasyslog);
    # later success
    $self->assert(grep { m/Rename: user\x1Fcassandane\x1Fdest-name -> user\x1Fcassandane\x1Ffoo/ } @replicasyslog);
    # replication fixes itself
    $self->check_replication('cassandane');
}

#
# Test replication of messages APPENDed to the master
#
sub test_splitbrain_masterexpunge
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    my $replica_store = $self->{replica_store};

    xlog $self, "generating messages A..D";
    my %exp;
    $exp{A} = $self->make_message("Message A", store => $master_store);
    $exp{B} = $self->make_message("Message B", store => $master_store);
    $exp{C} = $self->make_message("Message C", store => $master_store);
    $exp{D} = $self->make_message("Message D", store => $master_store);

    xlog $self, "Before replication, the master should have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "Before replication, the replica should have no messages";
    $self->check_messages({}, store => $replica_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication, the master should still have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should now have all four messages";
    $self->check_messages(\%exp, store => $replica_store);

    my %mexp = %exp;
    my %rexp = %exp;

    $mexp{E} = $self->make_message("Message E", store => $master_store);
    $rexp{F} = $self->make_message("Message F", store => $replica_store);

    # uid is 5 at both ends
    $rexp{F}->set_attribute(uid => 5);

    xlog $self, "No replication, the master should have its 5 messages";
    $self->check_messages(\%mexp, store => $master_store);
    xlog $self, "No replication, the replica should have the other 5 messages";
    $self->check_messages(\%rexp, store => $replica_store);

    xlog $self, "Delete and expunge the message on the master";
    my $talk = $master_store->get_client();
    $master_store->_select();
    $talk->store('5', '+flags', '(\\Deleted)');
    $talk->expunge();
    delete $mexp{E};

    xlog $self, "No replication, the master now only has 4 messages";
    $self->check_messages(\%mexp, store => $master_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    %exp = (%mexp, %rexp);
    # we know that the message should be prompoted to UID 6
    $exp{F}->set_attribute(uid => 6);
    xlog $self, "After replication, the master should have all 5 messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should have the same 5 messages";
    $self->check_messages(\%exp, store => $replica_store);

    # We should have generated a SYNCERROR/SYNCNOTICE or two
    my @master_lines = $self->{instance}->getsyslog();
    $self->assert_matches(qr/SYNC(?:ERROR|NOTICE): guid mismatch/, "@master_lines");
    my @replica_lines = $self->{replica}->getsyslog();
    $self->assert_matches(qr/SYNC(?:ERROR|NOTICE): guid mismatch/, "@replica_lines");
}

#
# Test replication of messages APPENDed to the master
#
sub test_splitbrain_replicaexpunge
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    my $replica_store = $self->{replica_store};

    xlog $self, "generating messages A..D";
    my %exp;
    $exp{A} = $self->make_message("Message A", store => $master_store);
    $exp{B} = $self->make_message("Message B", store => $master_store);
    $exp{C} = $self->make_message("Message C", store => $master_store);
    $exp{D} = $self->make_message("Message D", store => $master_store);

    xlog $self, "Before replication, the master should have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "Before replication, the replica should have no messages";
    $self->check_messages({}, store => $replica_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication, the master should still have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should now have all four messages";
    $self->check_messages(\%exp, store => $replica_store);

    my %mexp = %exp;
    my %rexp = %exp;

    $mexp{E} = $self->make_message("Message E", store => $master_store);
    $rexp{F} = $self->make_message("Message F", store => $replica_store);

    # uid is 5 at both ends
    $rexp{F}->set_attribute(uid => 5);

    xlog $self, "No replication, the master should have its 5 messages";
    $self->check_messages(\%mexp, store => $master_store);
    xlog $self, "No replication, the replica should have the other 5 messages";
    $self->check_messages(\%rexp, store => $replica_store);

    xlog $self, "Delete and expunge the message on the master";
    my $rtalk = $replica_store->get_client();
    $replica_store->_select();
    $rtalk->store('5', '+flags', '(\\Deleted)');
    $rtalk->expunge();
    delete $rexp{F};

    xlog $self, "No replication, the replica now only has 4 messages";
    $self->check_messages(\%rexp, store => $replica_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    %exp = (%mexp, %rexp);
    # we know that the message should be prompoted to UID 6
    $exp{E}->set_attribute(uid => 6);
    xlog $self, "After replication, the master should have all 5 messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should have the same 5 messages";
    $self->check_messages(\%exp, store => $replica_store);

    # We should have generated a SYNCERROR or two
    my @lines = $self->{instance}->getsyslog();
    $self->assert_matches(qr/SYNCERROR: guid mismatch/, "@lines");
}

#
# Test replication of messages APPENDed to the master
#
sub test_splitbrain_bothexpunge
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    my $replica_store = $self->{replica_store};

    xlog $self, "generating messages A..D";
    my %exp;
    $exp{A} = $self->make_message("Message A", store => $master_store);
    $exp{B} = $self->make_message("Message B", store => $master_store);
    $exp{C} = $self->make_message("Message C", store => $master_store);
    $exp{D} = $self->make_message("Message D", store => $master_store);

    xlog $self, "Before replication, the master should have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "Before replication, the replica should have no messages";
    $self->check_messages({}, store => $replica_store);

    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication, the master should still have all four messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should now have all four messages";
    $self->check_messages(\%exp, store => $replica_store);

    my %mexp = %exp;
    my %rexp = %exp;

    $mexp{E} = $self->make_message("Message E", store => $master_store);
    $rexp{F} = $self->make_message("Message F", store => $replica_store);

    # uid is 5 at both ends
    $rexp{F}->set_attribute(uid => 5);

    xlog $self, "No replication, the master should have its 5 messages";
    $self->check_messages(\%mexp, store => $master_store);
    xlog $self, "No replication, the replica should have the other 5 messages";
    $self->check_messages(\%rexp, store => $replica_store);

    xlog $self, "Delete and expunge the message on the master";
    my $talk = $master_store->get_client();
    $master_store->_select();
    $talk->store('5', '+flags', '(\\Deleted)');
    $talk->expunge();
    delete $mexp{E};

    xlog $self, "Delete and expunge the message on the master";
    my $rtalk = $replica_store->get_client();
    $replica_store->_select();
    $rtalk->store('5', '+flags', '(\\Deleted)');
    $rtalk->expunge();
    delete $rexp{F};

    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication, the master should have just the original 4 messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication, the replica should have the same 4 messages";
    $self->check_messages(\%exp, store => $replica_store);
}

# trying to reproduce error reported in https://git.cyrus.foundation/T228
sub test_alternate_globalannots
    :NoStartInstances
{
    my ($self) = @_;

    # first, set a different annotation_db_path on the master server
    my $annotation_db_path = $self->{instance}->get_basedir()
                             . "/conf/non-default-annotations.db";
    $self->{instance}->{config}->set('annotation_db_path' => $annotation_db_path);

    # now we can start the instances
    $self->_start_instances();

    # A replication will automatically occur when the instances are started,
    # in order to make sure the cassandane user exists on both hosts.
    # So if we get here without crashing, replication works.
    xlog $self, "initial replication was successful";

    $self->assert(1);
}

sub assert_sieve_exists
{
    my ($self, $instance, $user, $scriptname) = @_;

    my $sieve_dir = $instance->get_sieve_script_dir($user);

    $self->assert(( -f "$sieve_dir/$scriptname.bc" ));
    $self->assert(( -f "$sieve_dir/$scriptname.script" ));
}

sub assert_sieve_not_exists
{
    my ($self, $instance, $user, $scriptname) = @_;

    my $sieve_dir = $instance->get_sieve_script_dir($user);

    $self->assert(( ! -f "$sieve_dir/$scriptname.bc" ));
    $self->assert(( ! -f "$sieve_dir/$scriptname.script" ));
}

sub assert_sieve_active
{
    my ($self, $instance, $user, $scriptname) = @_;

    my $sieve_dir = $instance->get_sieve_script_dir($user);

    $self->assert(( -l "$sieve_dir/defaultbc" ));
    $self->assert_str_equals("$scriptname.bc", readlink "$sieve_dir/defaultbc");
}

sub assert_sieve_noactive
{
    my ($self, $instance, $user) = @_;

    my $sieve_dir = $instance->get_sieve_script_dir($user);

    $self->assert(( ! -e "$sieve_dir/defaultbc" ),
                  "$sieve_dir/defaultbc exists");
    $self->assert(( ! -l "$sieve_dir/defaultbc" ),
                  "dangling $sieve_dir/defaultbc symlink exists");
}

sub assert_sieve_matches
{
    my ($self, $instance, $user, $scriptname, $scriptcontent) = @_;

    my $sieve_dir = $instance->get_sieve_script_dir($user);

    my $filename = "$sieve_dir/$scriptname.script";

    $self->assert(( -f $filename ));

    open my $f, '<', $filename or die "open $filename: $!\n";
    my $filecontent = do { local $/; <$f> };
    close $f;

    $self->assert_str_equals($scriptcontent, $filecontent);

    my $bcname = "$sieve_dir/$scriptname.bc";

    $self->assert(( -f $bcname ));
    my $filemtime = (stat $filename)[9];
    my $bcmtime = (stat $bcname)[9];

    $self->assert($bcmtime >= $filemtime);
}

sub test_sieve_replication
    :needs_component_sieve
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $scriptname = 'test1';
    my $scriptcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    # first, verify that sieve script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install sieve script on master
    $self->{instance}->install_sieve_script($scriptcontent, name=>$scriptname);

    # then, verify that sieve script exists on master but not on replica
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, run replication,
    $self->run_replication();
    $self->check_replication('cassandane');

    # then, verify that sieve script exists on both master and replica
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
}

sub test_sieve_replication_exists
    :needs_component_sieve
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $scriptname = 'test1';
    my $scriptcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    # first, verify that sieve script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install sieve script on both master and replica
    $self->{instance}->install_sieve_script($scriptcontent, name=>$scriptname);
    $self->{replica}->install_sieve_script($scriptcontent, name=>$scriptname);

    # then, verify that sieve script exists on both
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);

    # then, run replication,
    $self->run_replication();
    $self->check_replication('cassandane');

    # then, verify that sieve script still exists on both master and replica
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
}

sub test_sieve_replication_different
    :needs_component_sieve
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $script1name = 'test1';
    my $script1content = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    my $script2name = 'test2';
    my $script2content = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "more testing";
}
EOF

    # first, verify that neither script exists on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{instance}, $user, $script2name);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{replica}, $user, $script2name);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install different sieve script on master and replica
    $self->{instance}->install_sieve_script($script1content, name=>$script1name);
    $self->{replica}->install_sieve_script($script2content, name=>$script2name);

    # then, verify that each sieve script exists on one only
    $self->assert_sieve_exists($self->{instance}, $user, $script1name);
    $self->assert_sieve_active($self->{instance}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{instance}, $user, $script2name);

    $self->assert_sieve_exists($self->{replica}, $user, $script2name);
    $self->assert_sieve_active($self->{replica}, $user, $script2name);
    $self->assert_sieve_not_exists($self->{replica}, $user, $script1name);

    # then, run replication,
    # the one that exists on master only will be replicated
    # the one that exists on replica only will be deleted
    $self->run_replication();
    $self->check_replication('cassandane');

    # then, verify that scripts are in expected state
    $self->assert_sieve_exists($self->{instance}, $user, $script1name);
    $self->assert_sieve_active($self->{instance}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{instance}, $user, $script2name);

    $self->assert_sieve_exists($self->{replica}, $user, $script1name);
    $self->assert_sieve_active($self->{replica}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{replica}, $user, $script2name);
}

sub test_sieve_replication_stale
    :needs_component_sieve
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $scriptname = 'test1';
    my $scriptoldcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    my $scriptnewcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "more testing";
}
EOF

    # first, verify that script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install "old" script on replica...
    $self->{replica}->install_sieve_script($scriptoldcontent, name=>$scriptname);

    # ... and "new" script on master, a little later
    sleep 2;
    $self->{instance}->install_sieve_script($scriptnewcontent, name=>$scriptname);

    # then, verify that different sieve script content exists at each end
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);
    $self->assert_sieve_matches($self->{instance}, $user, $scriptname,
                                $scriptnewcontent);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
    $self->assert_sieve_matches($self->{replica}, $user, $scriptname,
                                $scriptoldcontent);

    # then, run replication,
    # the one that exists on replica is different to and older than the one
    # on master, so it will be replaced with the one from master
    $self->run_replication();
    $self->check_replication('cassandane');

    # then, verify that scripts are in expected state
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);
    $self->assert_sieve_matches($self->{instance}, $user, $scriptname,
                                $scriptnewcontent);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
    $self->assert_sieve_matches($self->{replica}, $user, $scriptname,
                                $scriptnewcontent);
}

sub test_sieve_replication_delete_unactivate
    :needs_component_sieve
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $scriptname = 'test1';
    my $scriptcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    # first, verify that sieve script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install sieve script on replica only
    $self->{replica}->install_sieve_script($scriptcontent, name=>$scriptname);

    # then, verify that sieve script exists on replica only
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);

    # then, run replication,
    $self->run_replication();
    $self->check_replication('cassandane');

    # then, verify that sieve script no longer exists on either
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user, $scriptname);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user, $scriptname);
}

sub test_sieve_replication_unixhs
    :needs_component_sieve :UnixHierarchySep
{
    my ($self) = @_;

    my $user = 'some.body';
    my $scriptname = 'test1';
    my $scriptcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF
    $self->{instance}->create_user($user);

    # first, verify that sieve script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install sieve script on master
    $self->{instance}->install_sieve_script($scriptcontent,
                                            name=>$scriptname,
                                            username=>$user);

    # then, verify that sieve script exists on master but not on replica
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, run replication,
    $self->run_replication(user=>$user);
    $self->check_replication($user);

    # then, verify that sieve script exists on both master and replica
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
}

sub test_sieve_replication_exists_unixhs
    :needs_component_sieve :UnixHierarchySep
{
    my ($self) = @_;

    my $user = 'some.body';
    my $scriptname = 'test1';
    my $scriptcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF
    $self->{instance}->create_user($user);

    # first, verify that sieve script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install sieve script on both master and replica
    $self->{instance}->install_sieve_script($scriptcontent,
                                            name=>$scriptname,
                                            username=>$user);
    $self->{replica}->install_sieve_script($scriptcontent,
                                           name=>$scriptname,
                                           username=>$user);

    # then, verify that sieve script exists on both
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);

    # then, run replication,
    $self->run_replication(user=>$user);
    $self->check_replication($user);

    # then, verify that sieve script still exists on both master and replica
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
}

sub test_sieve_replication_different_unixhs
    :needs_component_sieve :UnixHierarchySep
{
    my ($self) = @_;

    my $user = 'some.body';
    my $script1name = 'test1';
    my $script1content = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    my $script2name = 'test2';
    my $script2content = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "more testing";
}
EOF
    $self->{instance}->create_user($user);

    # first, verify that neither script exists on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{instance}, $user, $script2name);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{replica}, $user, $script2name);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install different sieve script on master and replica
    $self->{instance}->install_sieve_script($script1content,
                                            name=>$script1name,
                                            username=>$user);
    $self->{replica}->install_sieve_script($script2content,
                                           name=>$script2name,
                                           username=>$user);

    # then, verify that each sieve script exists on one only
    $self->assert_sieve_exists($self->{instance}, $user, $script1name);
    $self->assert_sieve_active($self->{instance}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{instance}, $user, $script2name);

    $self->assert_sieve_exists($self->{replica}, $user, $script2name);
    $self->assert_sieve_active($self->{replica}, $user, $script2name);
    $self->assert_sieve_not_exists($self->{replica}, $user, $script1name);

    # then, run replication,
    # the one that exists on master only will be replicated
    # the one that exists on replica only will be deleted
    $self->run_replication(user=>$user);
    $self->check_replication($user);

    # then, verify that scripts are in expected state
    $self->assert_sieve_exists($self->{instance}, $user, $script1name);
    $self->assert_sieve_active($self->{instance}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{instance}, $user, $script2name);

    $self->assert_sieve_exists($self->{replica}, $user, $script1name);
    $self->assert_sieve_active($self->{replica}, $user, $script1name);
    $self->assert_sieve_not_exists($self->{replica}, $user, $script2name);
}

sub test_sieve_replication_stale_unixhs
    :needs_component_sieve :UnixHierarchySep
{
    my ($self) = @_;

    my $user = 'some.body';
    my $scriptname = 'test1';
    my $scriptoldcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF

    my $scriptnewcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "more testing";
}
EOF
    $self->{instance}->create_user($user);

    # first, verify that script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install "old" script on replica...
    $self->{replica}->install_sieve_script($scriptoldcontent,
                                           name=>$scriptname,
                                           username=>$user);

    # ... and "new" script on master, a little later
    sleep 2;
    $self->{instance}->install_sieve_script($scriptnewcontent,
                                            name=>$scriptname,
                                            username=>$user);

    # then, verify that different sieve script content exists at each end
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);
    $self->assert_sieve_matches($self->{instance}, $user, $scriptname,
                                $scriptnewcontent);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
    $self->assert_sieve_matches($self->{replica}, $user, $scriptname,
                                $scriptoldcontent);

    # then, run replication,
    # the one that exists on replica is different to and older than the one
    # on master, so it will be replaced with the one from master
    $self->run_replication(user=>$user);
    $self->check_replication($user);

    # then, verify that scripts are in expected state
    $self->assert_sieve_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_active($self->{instance}, $user, $scriptname);
    $self->assert_sieve_matches($self->{instance}, $user, $scriptname,
                                $scriptnewcontent);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);
    $self->assert_sieve_matches($self->{replica}, $user, $scriptname,
                                $scriptnewcontent);
}

sub test_sieve_replication_delete_unactivate_unixhs
    :needs_component_sieve :UnixHierarchySep
{
    my ($self) = @_;

    my $user = 'some.body';
    my $scriptname = 'test1';
    my $scriptcontent = <<'EOF';
require ["reject","fileinto"];
if address :is :all "From" "autoreject@example.org"
{
        reject "testing";
}
EOF
    $self->{instance}->create_user($user);

    # first, verify that sieve script does not exist on master or replica
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user);

    # then, install sieve script on replica only
    $self->{replica}->install_sieve_script($scriptcontent,
                                           name=>$scriptname,
                                           username=>$user);

    # then, verify that sieve script exists on replica only
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user, $scriptname);

    $self->assert_sieve_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_active($self->{replica}, $user, $scriptname);

    # then, run replication,
    $self->run_replication(user=>$user);
    $self->check_replication($user);

    # then, verify that sieve script no longer exists on either
    $self->assert_sieve_not_exists($self->{instance}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{instance}, $user, $scriptname);

    $self->assert_sieve_not_exists($self->{replica}, $user, $scriptname);
    $self->assert_sieve_noactive($self->{replica}, $user, $scriptname);
}

sub slurp_file
{
    my ($filename) = @_;

    local $/;
    open my $f, '<', $filename
        or die "Cannot open $filename for reading: $!\n";
    my $str = <$f>;
    close $f;

    return $str;
}

sub test_replication_mailbox_too_old
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $exit_code;

    my $master_instance = $self->{instance};
    my $replica_instance = $self->{replica};

    my $inbox = "user.$user";
    my $mastertalk = $self->{master_store}->get_client();
    my $status = $mastertalk->status($inbox, "(mailboxid)");
    my $inboxid = $status->{mailboxid}[0];
    my $master_dir = $master_instance->folder_to_directory($inboxid);
    my $replica_dir = $replica_instance->folder_to_directory($inboxid);

    # replicate now to create mailbox entry and directory on replica
    $exit_code = 0;
    $self->run_replication(
        user => $user,
        handlers => {
            exited_abnormally => sub { (undef, $exit_code) = @_; },
        },
    );
    $self->assert_equals(0, $exit_code);

    # logs will all be in the master instance, because that's where
    # sync_client runs from.
    my $log_base = "$master_instance->{basedir}/$self->{_name}";

    # add a version9 mailbox to the replica only, and try to replicate.
    # replication will fail, because the initial GET USER will barf
    # upon encountering the old mailbox.
    $replica_instance->install_old_mailbox($user, 9, $replica_dir);
    my $log_firstreject = "$log_base-firstreject.stderr";
    $exit_code = 0;
    $self->run_replication(
        user => $user,
        handlers => {
            exited_abnormally => sub { (undef, $exit_code) = @_; },
        },
        redirects => { stderr => $log_firstreject },
    );
    $self->assert_equals(1, $exit_code);
    $self->assert(qr/USER received NO response: IMAP_MAILBOX_NOTSUPPORTED/,
                  slurp_file($log_firstreject));

    # add the version9 mailbox to the master, and try to replicate.
    # mailbox will be found and rejected locally, and replication will
    # fail.
    $master_instance->install_old_mailbox($user, 9, $master_dir);
    my $log_localreject = "$log_base-localreject.stderr";
    $exit_code = 0;
    $self->run_replication(
        user => $user,
        handlers => {
            exited_abnormally => sub { (undef, $exit_code) = @_; },
        },
        redirects => { stderr => $log_localreject },
    );
    $self->assert_equals(1, $exit_code);
    $self->assert(qr/Operation is not supported on mailbox/,
                  slurp_file($log_localreject));

    # upgrade the version9 mailbox on the master, and try to replicate.
    # replication will fail, because the initial GET USER will barf
    # upon encountering the old mailbox.
    $master_instance->run_command({ cyrus => 1 }, qw(reconstruct -V max -u), $user);

    my $log_remotereject = "$log_base-remotereject.stderr";
    $exit_code = 0;
    $self->run_replication(
        user => $user,
        handlers => {
            exited_abnormally => sub { (undef, $exit_code) = @_; },
        },
        redirects => { stderr => $log_remotereject },
    );
    $self->assert_equals(1, $exit_code);
    $self->assert(qr/USER received NO response: IMAP_MAILBOX_NOTSUPPORTED/,
                  slurp_file($log_remotereject));

    # upgrade the version9 mailbox on the replica, and try to replicate.
    # replication will succeed because both ends are capable of replication.
    $replica_instance->run_command({ cyrus => 1 }, qw(reconstruct -V max -u), $user);
    $exit_code = 0;
    $self->run_replication(
        user => $user,
        handlers => {
            exited_abnormally => sub { (undef, $exit_code) = @_; },
        },
    );
    $self->assert_equals(0, $exit_code);
}

# XXX need a test for version 10 mailbox without guids in it!

sub test_replication_mailbox_new_enough
{
    my ($self) = @_;

    my $user = 'cassandane';
    my $exit_code = 0;

    my $admintalk = $self->{adminstore}->get_client();

    my $mailbox10 = "user.$user.version10";
    my $mailbox12 = "user.$user.version12";

    $admintalk->create($mailbox10);
    $admintalk->create($mailbox12);

    my $status = $admintalk->status($mailbox10, "(mailboxid)");
    my $id10 = $status->{mailboxid}[0];

    $status = $admintalk->status($mailbox12, "(mailboxid)");
    my $id12 = $status->{mailboxid}[0];

    # successfully replicate a mailbox new enough to contain guids
    my $dest_dir = $self->{instance}->folder_to_directory($id10);
    $self->{instance}->install_old_mailbox($user, 10, $dest_dir);
    $self->run_replication(mailbox => $mailbox10);

    # successfully replicate a mailbox new enough to contain guids
    $dest_dir = $self->{instance}->folder_to_directory($id12);
    $self->{instance}->install_old_mailbox($user, 12, $dest_dir);
    $self->run_replication(mailbox => $mailbox12);
}

#* create mailbox on master with no messages
#* sync_client to get it copied to replica
#* create a message in the mailbox on replica (imaptalk on replica_store)
#* delete the message from the replica (with expunge_mode default or expunge_mode immediate... try both)
#* run sync_client on the master again and make sure it successfully syncs up

sub test_replication_repair_zero_msgs
{
    my ($self) = @_;

    my $mastertalk = $self->{master_store}->get_client();
    my $replicatalk = $self->{replica_store}->get_client();

    # raise the modseq on the master end
    $mastertalk->setmetadata("INBOX", "/shared/comment", "foo");
    $mastertalk->setmetadata("INBOX", "/shared/comment", "");
    $mastertalk->setmetadata("INBOX", "/shared/comment", "foo");
    $mastertalk->setmetadata("INBOX", "/shared/comment", "");

    my $msg = $self->make_message("to be deleted", store => $self->{replica_store});

    $replicatalk->store($msg->{attrs}->{uid}, '+flags', '(\\deleted)');
    $replicatalk->expunge();

    $self->run_replication(user => 'cassandane');
}

sub test_replication_with_modified_seen_flag
{
    my ($self) = @_;

    my $master_store = $self->{master_store};
    $master_store->set_fetch_attributes(qw(uid flags));

    my $replica_store = $self->{replica_store};
    $replica_store->set_fetch_attributes(qw(uid flags));


    xlog $self, "generating messages A & B";
    my %exp;
    $exp{A} = $self->make_message("Message A", store => $master_store);
    $exp{A}->set_attributes(id => 1, uid => 1, flags => []);
    $exp{B} = $self->make_message("Message B", store => $master_store);
    $exp{B}->set_attributes(id => 2, uid => 2, flags => []);

    xlog $self, "Before replication: Ensure that master has two messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "Before replication: Ensure that replica has no messages";
    $self->check_messages({}, store => $replica_store);

    xlog $self, "Run Replication!";
    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication: Ensure that master has two messages";
    $self->check_messages(\%exp, store => $master_store);
    xlog $self, "After replication: Ensure replica now has two messages";
    $self->check_messages(\%exp, store => $replica_store);

    xlog $self, "Set \\Seen on Message B";
    my $mtalk = $master_store->get_client();
    $master_store->_select();
    $mtalk->store('2', '+flags', '(\\Seen)');
    $exp{B}->set_attributes(flags => ['\\Seen']);
    $mtalk->unselect();
    xlog $self, "Before replication: Ensure that master has two messages and flags are set";
    $self->check_messages(\%exp, store => $master_store);

    xlog $self, "Before replication: Ensure that replica does not have the \\Seen flag set on Message B";
    my $rtalk = $replica_store->get_client();
    $replica_store->_select();
    my $res = $rtalk->fetch("2", "(flags)");
    my $flags = $res->{2}->{flags};
    $self->assert(not grep { $_ eq "\\Seen"} @$flags);

    xlog $self, "Run Replication!";
    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication: Ensure that replica does have the \\Seen flag set on Message B";
    $rtalk = $replica_store->get_client();
    $replica_store->_select();
    $res = $rtalk->fetch("2", "(flags)");
    $flags = $res->{2}->{flags};
    $self->assert(grep { $_ eq "\\Seen"} @$flags);

    xlog $self, "Clear \\Seen flag on Message B on master.";
    $mtalk = $master_store->get_client();
    $master_store->_select();
    $mtalk->store('2', '-flags', '(\\Seen)');

    xlog $self, "Run Replication!";
    $self->run_replication();
    $self->check_replication('cassandane');

    xlog $self, "After replication: Check both master and replica has no \\Seen flag on Message C";
    $mtalk = $master_store->get_client();
    $master_store->_select();
    $res = $mtalk->fetch("2", "(flags)");
    $flags = $res->{2}->{flags};
    $self->assert(not grep { $_ eq "\\Seen"} @$flags);

    $rtalk = $replica_store->get_client();
    $replica_store->_select();
    $res = $rtalk->fetch("3", "(flags)");
    $flags = $res->{3}->{flags};
    $self->assert(not grep { $_ eq "\\Seen"} @$flags);
}

sub assert_user_sub_exists
{
    my ($self, $instance, $user) = @_;

    my $subs = $instance->get_conf_user_file($user, 'sub');

    xlog $self, "Looking for subscriptions file $subs";

    $self->assert(( -f $subs ));
}

sub assert_user_sub_not_exists
{
    my ($self, $instance, $user) = @_;

    my $subs = $instance->get_conf_user_file($user, 'sub');

    xlog $self, "Looking for subscriptions file $subs";

    $self->assert(( ! -f $subs ));
}

sub test_subscriptions
{
    my ($self) = @_;

    my $user = 'brandnew';
    $self->{instance}->create_user($user);

    # verify that subs file does not exist on master
    # verify that subs file does not exist on replica
    $self->assert_user_sub_not_exists($self->{instance}, $user);
    $self->assert_user_sub_not_exists($self->{replica}, $user);

    # set up and verify some subscriptions on master
    my $mastersvc = $self->{instance}->get_service('imap');
    my $masterstore = $mastersvc->create_store(username => $user);
    my $mastertalk = $masterstore->get_client();

    $mastertalk->create("INBOX.Test") || die;
    $mastertalk->create("INBOX.Test.Sub") || die;
    $mastertalk->create("INBOX.Test Foo") || die;
    $mastertalk->create("INBOX.Test Bar") || die;
    $mastertalk->subscribe("INBOX") || die;
    $mastertalk->subscribe("INBOX.Test") || die;
    $mastertalk->subscribe("INBOX.Test.Sub") || die;
    $mastertalk->subscribe("INBOX.Test Foo") || die;
    $mastertalk->delete("INBOX.Test.Sub") || die;

    my $subdata = $mastertalk->lsub("", "*");
    $self->assert_deep_equals($subdata, [
          [
            [
              '\\HasChildren'
            ],
            '.',
            'INBOX'
          ],
          [
            [
              '\\HasChildren'
            ],
            '.',
            'INBOX.Test'
          ],
          [
            [],
            '.',
            'INBOX.Test Foo'
          ],
    ]);

    # drop the conf dir lock, so the subs get written out
    $mastertalk->logout();

    # verify that subs file exists on master
    # verify that subs file does not exist on replica
    $self->assert_user_sub_exists($self->{instance}, $user);
    $self->assert_user_sub_not_exists($self->{replica}, $user);

    # run replication
    $self->run_replication(user => $user);
    $self->check_replication($user);

    # verify that subs file exists on master
    # verify that subs file exists on replica
    $self->assert_user_sub_exists($self->{instance}, $user);
    $self->assert_user_sub_exists($self->{replica}, $user);

    # verify replica store can see subs
    my $replicasvc = $self->{replica}->get_service('imap');
    my $replicastore = $replicasvc->create_store(username => $user);
    my $replicatalk = $replicastore->get_client();

    $subdata = $replicatalk->lsub("", "*");
    $self->assert_deep_equals($subdata, [
          [
            [
              '\\HasChildren'
            ],
            '.',
            'INBOX'
          ],
          [
            [
              '\\HasChildren'
            ],
            '.',
            'INBOX.Test'
          ],
          [
            [],
            '.',
            'INBOX.Test Foo'
          ],
    ]);
}

sub test_subscriptions_unixhs
    :UnixHierarchySep
{
    my ($self) = @_;

    my $user = 'brand.new';
    $self->{instance}->create_user($user);

    # verify that subs file does not exist on master
    # verify that subs file does not exist on replica
    $self->assert_user_sub_not_exists($self->{instance}, $user);
    $self->assert_user_sub_not_exists($self->{replica}, $user);

    # set up and verify some subscriptions on master
    my $mastersvc = $self->{instance}->get_service('imap');
    my $masterstore = $mastersvc->create_store(username => $user);
    my $mastertalk = $masterstore->get_client();

    $mastertalk->create("INBOX/Test") || die;
    $mastertalk->create("INBOX/Test/Sub") || die;
    $mastertalk->create("INBOX/Test Foo") || die;
    $mastertalk->create("INBOX/Test Bar") || die;
    $mastertalk->subscribe("INBOX") || die;
    $mastertalk->subscribe("INBOX/Test") || die;
    $mastertalk->subscribe("INBOX/Test/Sub") || die;
    $mastertalk->subscribe("INBOX/Test Foo") || die;
    $mastertalk->delete("INBOX/Test/Sub") || die;

    my $subdata = $mastertalk->lsub("", "*");
    $self->assert_deep_equals($subdata, [
          [
            [
              '\\HasChildren'
            ],
            '/',
            'INBOX'
          ],
          [
            [
              '\\HasChildren'
            ],
            '/',
            'INBOX/Test'
          ],
          [
            [],
            '/',
            'INBOX/Test Foo'
          ],
    ]);

    # drop the conf dir lock, so the subs get written out
    $mastertalk->logout();

    # verify that subs file exists on master
    # verify that subs file does not exist on replica
    $self->assert_user_sub_exists($self->{instance}, $user);
    $self->assert_user_sub_not_exists($self->{replica}, $user);

    # run replication
    $self->run_replication(user => $user);
    $self->check_replication($user);

    # verify that subs file exists on master
    # verify that subs file exists on replica
    $self->assert_user_sub_exists($self->{instance}, $user);
    $self->assert_user_sub_exists($self->{replica}, $user);

    # verify replica store can see subs
    my $replicasvc = $self->{replica}->get_service('imap');
    my $replicastore = $replicasvc->create_store(username => $user);
    my $replicatalk = $replicastore->get_client();

    $subdata = $replicatalk->lsub("", "*");
    $self->assert_deep_equals($subdata, [
          [
            [
              '\\HasChildren'
            ],
            '/',
            'INBOX'
          ],
          [
            [
              '\\HasChildren'
            ],
            '/',
            'INBOX/Test'
          ],
          [
            [],
            '/',
            'INBOX/Test Foo'
          ],
    ]);
}

# this is testing a bug where DELETED namespace lookup in mboxlist_mboxtree
# wasn't correctly looking only for children of that name, so it would try
# to delete the wrong user's mailbox.
sub test_userprefix
    :DelayedDelete
{
    my ($self) = @_;
    $self->{instance}->create_user("ua");
    $self->{instance}->create_user("uab");

    my $mastersvc = $self->{instance}->get_service('imap');
    my $astore = $mastersvc->create_store(username => "ua");
    my $atalk = $astore->get_client();
    my $bstore = $mastersvc->create_store(username => "uab");
    my $btalk = $bstore->get_client();

    xlog "Creating some users with some deleted mailboxes";
    $atalk->create("INBOX.hi");
    $atalk->create("INBOX.no");
    $atalk->delete("INBOX.hi");

    $btalk->create("INBOX.boo");
    $btalk->create("INBOX.noo");
    $btalk->delete("INBOX.boo");

    $self->run_replication(user => "ua");
    $self->run_replication(user => "uab");

    my $masterstore = $mastersvc->create_store(username => 'admin');
    my $admintalk = $masterstore->get_client();

    xlog "Deleting the user with the prefix name";
    $admintalk->delete("user.ua");
    $self->run_replication(user => "ua");
    $self->run_replication(user => "uab");
    # This would fail at the end with syslog IOERRORs before the bugfix:
    # >1580698085>S1 SYNCAPPLY UNUSER ua
    # <1580698085<* BYE Fatal error: Internal error: assertion failed: imap/mboxlist.c: 868: user_isnamespacelocked(userid)
    # 0248020101/sync_client[20041]: IOERROR: UNUSER received * response: 
    # Error from sync_do_user(ua): bailing out!
}

1;
