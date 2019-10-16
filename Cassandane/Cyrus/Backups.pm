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

package Cassandane::Cyrus::Backups;
use strict;
use warnings;
use Data::Dumper;
use JSON::XS;

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;
use Cassandane::Instance;

$Data::Dumper::Sortkeys = 1;

sub new
{
    my $class = shift;
    return $class->SUPER::new({ backups => 1, adminstore => 1 }, @_);
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

sub cyr_backup_json
{
    my ($self, $params, $subcommand, @args) = @_;

    die "params not a hashref"
        if defined $params and ref $params ne 'HASH';
    die "invalid subcommand: $subcommand"
        if not grep { $_ eq $subcommand } qw(chunks mailboxes messages headers);

    my $instance = $params->{instance} // $self->{backups};
    my $user = $params->{user} // 'cassandane';
    my $mailbox = $params->{mailbox};

    my $out = "$instance->{basedir}/$self->{_name}"
          . "-cyr_backup-$user-json-$subcommand.stdout";
    my $err = "$instance->{basedir}/$self->{_name}"
          . "-cyr_backup-$user-json-$subcommand.stderr";

    my ($mode, $backup);
    if (defined $mailbox) {
        $mode = '-m';
        $backup = $mailbox;
    }
    else {
        $mode = '-u';
        $backup = $user;
    }

    $instance->run_command(
        { cyrus => 1,
          redirects => { 'stdout' => $out,
                         'stderr' => $err } },
        'cyr_backup', $mode, $backup, 'json', $subcommand, @args
    );

    local $/;
    open my $fh, '<', $out
        or die "Cannot open $out for reading: $!";
    my $data = JSON::decode_json(<$fh>);
    close $fh;

    return $data;
}

sub test_aaasetup
    :min_version_3_0
{
    my ($self) = @_;

    # does everything set up and tear down cleanly?
    $self->assert(1);
}

sub test_basic
    :min_version_3_0
{
    my ($self) = @_;

    # XXX probably don't do this like this
    $self->{instance}->run_command(
        { cyrus => 1 },
        qw(sync_client -vv -n backup -u cassandane)
    );

    my $chunks = $self->cyr_backup_json({}, 'chunks');

    $self->assert_equals(1, scalar @{$chunks});
    $self->assert_equals(0, $chunks->[0]->{offset});
    $self->assert_equals(1, $chunks->[0]->{id});
    # an empty chunk has a 29 byte prefix
    # make sure the chunk isn't empty -- it should at least send through
    # the state of an empty inbox
    $self->assert($chunks->[0]->{length} > 29);
}

sub test_messages
    :min_version_3_0
{
    my ($self) = @_;

    my %exp;

    $exp{A} = $self->make_message("Message A");
    $exp{B} = $self->make_message("Message B");
    $exp{C} = $self->make_message("Message C");
    $exp{D} = $self->make_message("Message D");

    # XXX probably don't do this like this
    $self->{instance}->run_command(
        { cyrus => 1 },
        qw(sync_client -vv -n backup -u cassandane)
    );

    my $messages = $self->cyr_backup_json({}, 'messages');

    # backup should contain four messages
    $self->assert_equals(4, scalar @{$messages});

    my $headers = $self->cyr_backup_json({}, 'headers', map { $_->{guid} } @{$messages});

    # transform out enough data for comparison purposes
    my %expected = map {
        $_->get_guid() => $_->get_header('X-Cassandane-Unique')
    } values %exp;

    my %actual = map {
        $_ => $headers->{$_}->{'X-Cassandane-Unique'}->[0]
    } keys %{$headers};

    $self->assert_deep_equals(\%expected, \%actual);
}

sub test_shared_mailbox
    :min_version_3_0
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();

    # should definitely not be able to create a user that would conflict
    # with where shared mailbox backups are stored!
    $admintalk->create('user.%SHARED');
    $self->assert_str_equals('no', $admintalk->get_last_completion_response());

    $admintalk->create('shared.folder');
    $self->assert_str_equals('ok', $admintalk->get_last_completion_response());
    $admintalk->setacl('shared.folder', 'cassandane' => 'lrswipkxtecdn');
    $self->assert_str_equals('ok', $admintalk->get_last_completion_response());

    $self->{store}->set_folder('shared.folder');
    my %exp;
    $exp{A} = $self->make_message("Message A");
    $exp{B} = $self->make_message("Message B");
    $exp{C} = $self->make_message("Message C");
    $exp{D} = $self->make_message("Message D");

    # XXX probably don't do this like this
    $self->{instance}->run_command(
        { cyrus => 1 },
        qw(sync_client -vv -n backup -m shared.folder)
    );

    my $messages = $self->cyr_backup_json({ mailbox => 'shared.folder'},
                                          'messages');

    # backup should contain four messages
    $self->assert_equals(4, scalar @{$messages});

    my $headers = $self->cyr_backup_json({ mailbox => 'shared.folder' },
                                         'headers',
                                         map { $_->{guid} } @{$messages});

    # transform out enough data for comparison purposes
    my %expected = map {
        $_->get_guid() => $_->get_header('X-Cassandane-Unique')
    } values %exp;

    my %actual = map {
        $_ => $headers->{$_}->{'X-Cassandane-Unique'}->[0]
    } keys %{$headers};

    $self->assert_deep_equals(\%expected, \%actual);

    # XXX probably don't do this like this
    $self->{backups}->run_command(
        { cyrus => 1 },
        qw(ctl_backups -S -vvv verify -m shared.folder)
    );
}

sub test_deleted_mailbox
    :min_version_3_0
{
    my ($self) = @_;

    my $usertalk = $self->{store}->get_client();
    $usertalk->create('INBOX.foo');
    $self->assert_str_equals('ok', $usertalk->get_last_completion_response());

    $self->{store}->set_folder('INBOX.foo');

    my %exp;
    $exp{A} = $self->make_message("Message A");
    $exp{B} = $self->make_message("Message B");
    $exp{C} = $self->make_message("Message C");
    $exp{D} = $self->make_message("Message D");

    # XXX probably don't do this like this
    $self->{instance}->run_command(
        { cyrus => 1 },
        qw(sync_client -vv -n backup -u cassandane)
    );

    # backup should contain four messages
    my $messages = $self->cyr_backup_json({}, 'messages');
    $self->assert_equals(4, scalar @{$messages});

    my $mailboxes = $self->cyr_backup_json({}, 'mailboxes');
	$self->assert_equals(2, scalar @{$mailboxes});
    $self->assert_deep_equals([qw(user.cassandane user.cassandane.foo)],
                              [ map { $_->{mboxname} } @{$mailboxes} ]);

    # delete the mailbox
    $usertalk->delete('INBOX.foo');
    $self->assert_str_equals('ok', $usertalk->get_last_completion_response());

    # XXX probably don't do this like this
    $self->{instance}->run_command(
        { cyrus => 1 },
        qw(sync_client -vv -n backup -u cassandane)
    );

    $messages = $self->cyr_backup_json({}, 'messages');
    $self->assert_equals(4, scalar @{$messages});

    $mailboxes = $self->cyr_backup_json({}, 'mailboxes');
	$self->assert_equals(2, scalar @{$mailboxes});
    $self->assert_deep_equals([qw(user.cassandane DELETED.user.cassandane.foo)],
                              [ map { $_->{mboxname} =~ s/\.[A-F0-9]{8}$//r }
									@{$mailboxes} ]);

	my $deleted_mboxname = $mailboxes->[1]->{mboxname};

    # should be able to find the correct backup by the deleted name
    # and see the four messages in it
    $messages = $self->cyr_backup_json({ mailbox => $deleted_mboxname },
                                       'messages');
    $self->assert_equals(4, scalar @{$messages});
}

1;
