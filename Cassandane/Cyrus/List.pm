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

package Cassandane::Cyrus::List;
use strict;
use warnings;
use DateTime;
use Data::Dumper;

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;
use Cassandane::Generator;
use Cassandane::MessageStoreFactory;
use Cassandane::Instance;

$Data::Dumper::Sortkeys = 1;

sub new
{
    my ($class, @args) = @_;

    my $config = Cassandane::Config->default()->clone();

    return $class->SUPER::new({ config => $config, adminstore => 1 }, @args);
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

sub _install_test_data
{
    my ($self, $test_data) = @_;

    my $imaptalk = $self->{store}->get_client();

    foreach my $row (@{$test_data}) {
        my ($cmd, $arg) = @{$row};
        if (ref $arg) {
            foreach (@{$arg}) {
                $imaptalk->$cmd($_) || die "$cmd '$_': $@";
            }
        }
        else {
            $imaptalk->$cmd($arg) || die "$cmd '$_': $@";
        }
    }
}

sub _assert_list_data
{
    my ($self, $actual, $expected_hiersep, $expected_mailbox_flags, $strict, $msg) = @_;

    # rearrange list output into order-agnostic format
    my %actual_hash;
    foreach my $row (@{$actual}) {
        my ($flags, $hiersep, $mailbox) = @{$row};

        $actual_hash{$mailbox} = {
            flags => { map { (lc($_) => 1) } @{$flags} },
            hiersep => $hiersep,
            mailbox => $mailbox,
        }
    }

    # check that expected data exists
    foreach my $mailbox (sort keys %{$expected_mailbox_flags}) {
        xlog $self, "expect mailbox: $mailbox";
        $self->assert(
            exists $actual_hash{$mailbox},
            "'$mailbox': mailbox not found"
        );

        $self->assert_str_equals(
            $actual_hash{$mailbox}->{hiersep},
            $expected_hiersep,
            "'$mailbox': got hierarchy separator '"
                . $actual_hash{$mailbox}->{hiersep}
                . "', expected '$expected_hiersep'"
        );

        my %expected_flags;
        if (ref $expected_mailbox_flags->{$mailbox}) {
            %expected_flags = map { (lc($_) => 1) }
                                  @{$expected_mailbox_flags->{$mailbox}};
        }
        else {
            %expected_flags = map { (lc($_) => 1) }
                                  split / /, $expected_mailbox_flags->{$mailbox};
        }

        # look for expected flags
        foreach my $flag (sort keys %expected_flags) {
            # https://tools.ietf.org/html/rfc5258#section-3.4:
            #    \NoInferiors implies \HasNoChildren
            #    \NonExistent implies \NoSelect
            if ($flag eq "\\hasnochildren") {
                $self->assert(
                    (exists $actual_hash{$mailbox}->{flags}->{$flag}
                     || exists $actual_hash{$mailbox}->{flags}->{"\\noinferiors"}),
                    "'$mailbox': missing flag '$flag'"
                );
            }
            elsif ($flag eq "\\noselect") {
                $self->assert(
                    (exists $actual_hash{$mailbox}->{flags}->{$flag}
                     || exists $actual_hash{$mailbox}->{flags}->{"\\nonexistent"}),
                    "'$mailbox': missing flag '$flag'"
                );
            }
            else {
                $self->assert(
                    exists $actual_hash{$mailbox}->{flags}->{$flag},
                    "'$mailbox': missing flag '$flag'"
                );
            }
        }

        next if not $strict;

        # look for unexpected flags
        foreach my $flag (sort keys %{$actual_hash{$mailbox}->{flags}}) {
            if ($flag eq "\\noinferiors") {
                $self->assert(
                    (exists $actual_hash{$mailbox}->{flags}->{$flag}
                     || exists $actual_hash{$mailbox}->{flags}->{"\\hasnochildren"}),
                    "'$mailbox': found unexpected flag '$flag'"
                );
            }
            elsif ($flag eq "\\nonexistent") {
                $self->assert(
                    (exists $actual_hash{$mailbox}->{flags}->{$flag}
                     || exists $actual_hash{$mailbox}->{flags}->{"\\noselect"}),
                    "'$mailbox': found unexpected flag '$flag'"
                );
            }
            else {
                $self->assert(
                    exists $expected_flags{$flag},
                    "'$mailbox': found unexected flag '$flag'"
                );
            }
        }
    }

    # check that unexpected data does not exist
    foreach my $mailbox (sort keys %actual_hash) {
        $self->assert(
            exists $expected_mailbox_flags->{$mailbox},
            "'$mailbox': found unexpected extra mailbox"
        );
    }
}

sub test_empty_mailbox
    :UnixHierarchySep
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();

    my $data = $imaptalk->list("", "");

    $self->_assert_list_data($data, '/', {
        '' => [ '\\Noselect' ],
    });
}

sub test_outlook_compatible_xlist_empty_mailbox
    :UnixHierarchySep
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();

    my $data = $imaptalk->xlist("", "");

    $self->assert(ref $data, "expected list response, got scalar: $data");

    $self->_assert_list_data($data, '/', {
        '' => [ '\\Noselect' ],
    });
}

# tests based on rfc 5258 examples:
# https://tools.ietf.org/html/rfc5258#section-5

sub test_rfc5258_ex01_list_all
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable Vegetable/Broccoli )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $alldata = $imaptalk->list("", "*");

    $self->_assert_list_data($alldata, '/', {
        'INBOX'                 => [qw( \\HasNoChildren )],
        'Fruit'                 => [qw( \\HasChildren )],
        'Fruit/Apple'           => [qw( \\HasNoChildren )],
        'Fruit/Banana'          => [qw( \\HasNoChildren )],
        'Tofu'                  => [qw( \\HasNoChildren )],
        'Vegetable'             => [qw( \\HasChildren )],
        'Vegetable/Broccoli'    => [qw( \\HasNoChildren )],
        'Vegetable/Corn'        => [qw( \\HasNoChildren )],
    });
}

sub test_recursivematch
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable Vegetable/Broccoli )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $subdata = $imaptalk->list([qw(SUBSCRIBED RECURSIVEMATCH)], "", "*");

    xlog(Dumper $subdata);
    $self->_assert_list_data($subdata, '/', {
        'INBOX'                 => '\\Subscribed',
        'Fruit/Banana'          => '\\Subscribed',
        'Fruit/Peach'           => [qw( \\NonExistent \\Subscribed )],
        'Vegetable'             => [qw( \\Subscribed \\HasChildren )], # HasChildren not required by spec, but cyrus tells us
        'Vegetable/Broccoli'    => '\\Subscribed',
    });
}

sub test_recursivematch_percent
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable Vegetable/Broccoli )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $subdata = $imaptalk->list([qw(SUBSCRIBED RECURSIVEMATCH)], "", "%");

    xlog(Dumper $subdata);
    $self->_assert_list_data($subdata, '/', {
        'INBOX'                 => [qw(  \\Subscribed )],
        'Fruit'                 => [qw( \\NonExistent \\HasChildren )],
        'Vegetable'             => [qw( \\Subscribed \\HasChildren )], # HasChildren not required by spec, but cyrus tells us
    });
}

sub test_rfc5258_ex02_list_subscribed
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable Vegetable/Broccoli )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $subdata = $imaptalk->list([qw(SUBSCRIBED)], "", "*");

    xlog(Dumper $subdata);
    $self->_assert_list_data($subdata, '/', {
        'INBOX'                 => '\\Subscribed',
        'Fruit/Banana'          => '\\Subscribed',
        'Fruit/Peach'           => [qw( \\NonExistent \\Subscribed )],
        'Vegetable'             => [qw( \\Subscribed \\HasChildren )], # HasChildren not required by spec, but cyrus tells us
        'Vegetable/Broccoli'    => '\\Subscribed',
    });
}

sub test_list_subscribed_return_children
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    xlog $self, "listing...";
    my $subdata = $imaptalk->list([qw(SUBSCRIBED)], "", "*", "RETURN", [qw(CHILDREN)]);

    xlog $self, "subscribed to: " . Dumper $subdata;
    $self->_assert_list_data($subdata, '/', {
        'INBOX'                 => [qw( \\Subscribed \\HasNoChildren )],
        'Fruit/Banana'          => [qw( \\Subscribed \\HasNoChildren )],
        'Fruit/Peach'           => [qw( \\NonExistent \\Subscribed \\HasNoChildren )],
        'Vegetable'             => [qw( \\Subscribed \\HasChildren )],
    }, 'strict');
}

sub test_list_subscribed_return_children_noaltns
    :UnixHierarchySep
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( INBOX/Fruit INBOX/Fruit/Apple INBOX/Fruit/Banana
                           INBOX/Fruit/Peach )] ],
        [ 'subscribe' => [qw( INBOX/Fruit/Banana INBOX/Fruit/Peach )] ],
        [ 'delete' => 'INBOX/Fruit/Peach' ],
        [ 'create' => [qw( INBOX/Tofu INBOX/Vegetable INBOX/Vegetable/Broccoli
                           INBOX/Vegetable/Corn )] ],
        [ 'subscribe' => [qw( INBOX/Vegetable )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    xlog $self, "listing...";
    my $subdata = $imaptalk->list([qw(SUBSCRIBED)], "", "*", "RETURN", [qw(CHILDREN)]);

    xlog $self, "subscribed to: " . Dumper $subdata;
    $self->_assert_list_data($subdata, '/', {
        'INBOX'                 => [qw( \\Subscribed \\HasChildren )],
        'INBOX/Fruit/Banana'    => [qw( \\Subscribed \\HasNoChildren )],
        'INBOX/Fruit/Peach'     => [qw( \\NonExistent \\Subscribed \\HasNoChildren )],
        'INBOX/Vegetable'       => [qw( \\Subscribed \\HasChildren )],
    }, 'strict');
}

sub test_list_return_subscribed
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable Vegetable/Broccoli )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $subdata = $imaptalk->list([qw()], "", "*", 'RETURN', [qw(SUBSCRIBED)]);

    xlog(Dumper $subdata);
    $self->_assert_list_data($subdata, '/', {
        'INBOX'                 => [qw( \\Subscribed \\HasNoChildren )],
        'Fruit'                 => [qw( \\HasChildren )],
        'Fruit/Apple'           => [qw( \\HasNoChildren )],
        'Fruit/Banana'          => [qw( \\Subscribed \\HasNoChildren )],
        'Tofu'                  => [qw( \\HasNoChildren )],
        'Vegetable'             => [qw( \\Subscribed \\HasChildren )],
        'Vegetable/Broccoli'    => [qw( \\Subscribed \\HasNoChildren )],
        'Vegetable/Corn'        => [qw( \\HasNoChildren )],
    });
}

sub test_rfc5258_ex03_children
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( Fruit Fruit/Apple Fruit/Banana Fruit/Peach)] ],
        [ 'subscribe' => [qw( Fruit/Banana Fruit/Peach )] ],
        [ 'delete' => 'Fruit/Peach' ],
        [ 'create' => [qw( Tofu Vegetable Vegetable/Broccoli Vegetable/Corn )] ],
        [ 'subscribe' => [qw( Vegetable Vegetable/Broccoli )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $data = $imaptalk->list(
        [qw()], "", "%", 'RETURN', [qw(CHILDREN)],
    );

    $self->_assert_list_data($data, '/', {
        'INBOX' => [ '\\HasNoChildren' ],
        'Fruit' => [ '\\HasChildren' ],
        'Tofu'  => [ '\\HasNoChildren' ],
        'Vegetable' => [ '\\HasChildren' ],
    });
}

# TODO not sure how to set up test data for remote mailboxes...
#sub test_rfc5258_ex04_remote_children
#{
#    my ($self) = @_;
#    $self->assert(0, 'FIXME test not implemented');
#}

#sub test_rfc5258_ex05_remote_subscribed
#{
#    my ($self) = @_;
#    $self->assert(0, 'FIXME test not implemented');
#}

#sub test_rfc5258_ex06_remote_return_subscribed
#{
#    my ($self) = @_;
#    $self->assert(0, 'FIXME test not implemented');
#}

sub test_rfc5258_ex07_multiple_mailbox_patterns
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => 'Drafts' ],
        [ 'create' => [qw(
            Sent Sent/March2004 Sent/December2003 Sent/August2004
        )] ],
        [ 'create' => [qw( Unlisted Unlisted/Foo )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $data = $imaptalk->list("", [qw( INBOX Drafts Sent/% )]);

    $self->_assert_list_data($data, '/', {
        'INBOX' => [ '\\HasNoChildren' ],
        'Drafts' => [ '\\HasNoChildren' ],
        'Sent/August2004' => [ '\\HasNoChildren' ],
        'Sent/December2003' => [ '\\HasNoChildren' ],
        'Sent/March2004' => [ '\\HasNoChildren' ],
    });
}

sub test_rfc5258_ex08_haschildren_childinfo
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => [qw( Foo Foo/Bar Foo/Baz Moo )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $data = $imaptalk->list("", "%", "RETURN", [qw( CHILDREN )]);

    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasNoChildren',
        'Foo'   => '\\HasChildren',
        'Moo'   => '\\HasNoChildren',
    });

    # TODO probably break the rest of this test out into 8a, 8b etc
    xlog('FIXME much more to test here...');
}

#sub test_rfc5258_ex09_childinfo
#{
#    my ($self) = @_;
#    $self->assert(0, 'FIXME test not implemented');
#}

#sub test_rfc5258_ex10_multiple_mailbox_patterns_childinfo
#{
#    my ($self) = @_;
#    $self->assert(0, 'FIXME test not implemented');
#}

#sub test_rfc5258_ex11_missing_hierarchy_elements
#{
#    my ($self) = @_;
#    $self->assert(0, 'FIXME test not implemented');
#}

sub test_folder_at_novirtdomains
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => [qw( foo@bar )] ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $data = $imaptalk->list("", "%", "RETURN", [qw( CHILDREN )]);

    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasNoChildren',
        'foo@bar' => '\\HasNoChildren',
    });
}

sub test_crossdomains
    :UnixHierarchySep :VirtDomains :CrossDomains :min_version_3_0
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    $admintalk->create("user/foo\@example.com");
    $admintalk->create("user/bar\@example.net");
    $admintalk->create("user/bar/Shared\@example.net"); # yay bogus domaining

    $admintalk->setacl("user/foo\@example.com", 'cassandane' => 'lrswipkxtecd');
    $admintalk->setacl("user/bar/Shared\@example.net", 'cassandane' => 'lrswipkxtecd');

    my $data = $imaptalk->list("", "*");

    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasNoChildren',
        'user/foo@example.com' => '\\HasNoChildren',
        'user/bar@example.net/Shared' => '\\HasNoChildren',
    });
}

sub test_crossdomains_alt
    :UnixHierarchySep :VirtDomains :CrossDomains :AltNamespace :min_version_3_0
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    $admintalk->create("user/foo\@example.com");
    $admintalk->create("user/bar\@example.net");
    $admintalk->create("user/bar/Shared\@example.net"); # yay bogus domaining

    $admintalk->setacl("user/foo\@example.com", 'cassandane' => 'lrswipkxtecd');
    $admintalk->setacl("user/bar/Shared\@example.net", 'cassandane' => 'lrswipkxtecd');

    my $data = $imaptalk->list("", "*");

    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasNoChildren',
        'Other Users/foo@example.com' => '\\HasNoChildren',
        'Other Users/bar@example.net/Shared' => '\\HasNoChildren',
    });
}

sub test_inbox_altnamespace
    :UnixHierarchySep :VirtDomains :CrossDomains :AltNamespace :min_version_3_0
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    foreach my $Folder ("user/cassandane/INBOX/sub", "user/cassandane/AEARLY",
                        "user/cassandane/sub2", "user/cassandane/sub2/achild",
                        "user/cassandane/INBOX/very/deep/one",
                        "user/cassandane/not/so/deep",
                        # stuff you can't see
                        "user/cassandane/INBOX",
                        "user/cassandane/inbox",
                        "user/cassandane/inbox/subnobody") {
        $admintalk->create($Folder);
        $admintalk->setacl($Folder, 'cassandane' => 'lrswipkxtecd');
    }

    my $data = $imaptalk->list("", "*");

    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasChildren',
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very/deep/one' => '\\HasNoChildren',
        'AEARLY' => '\\HasNoChildren',
        'not/so/deep' => '\\HasNoChildren',
        'sub2' => '\\HasChildren',
        'sub2/achild' => '\\HasNoChildren',
        'Alt Folders/INBOX' => '\\HasNoChildren \\Noinferiors',
        'Alt Folders/inbox' => '\\HasChildren',
        'Alt Folders/inbox/subnobody' => '\\HasNoChildren',
    });

    my $data2 = $imaptalk->list("", "%");

    $self->_assert_list_data($data2, '/', {
        'INBOX' => '\\HasChildren',
        'AEARLY' => '\\HasNoChildren',
        'not' => '\\HasChildren \\Noselect',
        'sub2' => '\\HasChildren',
        'Alt Folders' => '\\HasChildren \\Noselect',
    });

    my $data3 = $imaptalk->list("", "INBOX/%");

    $self->_assert_list_data($data3, '/', {
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very' => '\\HasChildren \\Noselect',
    });
}

# https://tools.ietf.org/html/rfc3501#section-6.3.8
# If the "%" wildcard is the last character of a
# mailbox name argument, matching levels of hierarchy
# are also returned.
sub test_percent
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # INBOX needs to exist even if we can't see it
    $admintalk->create('user.bar');

    foreach my $Folder ("user.cassandane.INBOX.sub", "user.cassandane.AEARLY",
                        "user.cassandane.sub2", "user.cassandane.sub2.achild",
                        "user.cassandane.INBOX.very.deep.one",
                        "user.cassandane.not.so.deep",
                        # stuff you can't see
                        "user.cassandane.INBOX",
                        "user.cassandane.inbox",
                        "user.cassandane.inbox.subnobody.deep",
                        "user.cassandane.Inbox.subnobody.deep",
                        # other users
                        "user.bar.Trash",
                        "user.foo",
                        "user.foo.really.deep",
                        # shared
                        "shared stuff.something") {
        $admintalk->create($Folder);
        $admintalk->setacl($Folder, 'cassandane' => 'lrswipkxtecd');
    }

    xlog $self, "List *";
    my $data = $imaptalk->list("", "*");
    $self->_assert_list_data($data, '.', {
        'INBOX' => '\\HasChildren',
        'INBOX.INBOX' => '\\HasChildren',
        'INBOX.INBOX.sub' => '\\HasNoChildren',
        'INBOX.INBOX.very.deep.one' => '\\HasNoChildren',
        'INBOX.Inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.inbox' => '\\HasChildren',
        'INBOX.inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.AEARLY' => '\\HasNoChildren',
        'INBOX.not.so.deep' => '\\HasNoChildren',
        'INBOX.sub2' => '\\HasChildren',
        'INBOX.sub2.achild' => '\\HasNoChildren',
        'user.bar.Trash' => '\\HasNoChildren',
        'user.foo' => '\\HasChildren',
        'user.foo.really.deep' => '\\HasNoChildren',
        'shared stuff.something' => '\\HasNoChildren',
    });

    #xlog $self, "LIST %";
    #$data = $imaptalk->list("", "%");
    #$self->_assert_list_data($data, '.', {
        #'INBOX' => '\\HasChildren',
        #'user' => '\\Noselect \\HasChildren',
        #'shared stuff' => '\\Noselect \\HasChildren',
    #});

    xlog $self, "List *%";
    $data = $imaptalk->list("", "*%");
    $self->_assert_list_data($data, '.', {
        'INBOX' => '\\HasChildren',
        'INBOX.INBOX' => '\\HasChildren',
        'INBOX.INBOX.sub' => '\\HasNoChildren',
        'INBOX.INBOX.very' => '\\Noselect \\HasChildren',
        'INBOX.INBOX.very.deep' => '\\Noselect \\HasChildren',
        'INBOX.INBOX.very.deep.one' => '\\HasNoChildren',
        'INBOX.Inbox' => '\\Noselect \\HasChildren',
        'INBOX.Inbox.subnobody' => '\\Noselect \\HasChildren',
        'INBOX.Inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.inbox' => '\\HasChildren',
        'INBOX.inbox.subnobody' => '\\Noselect \\HasChildren',
        'INBOX.inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.AEARLY' => '\\HasNoChildren',
        'INBOX.not' => '\\Noselect \\HasChildren',
        'INBOX.not.so' => '\\Noselect \\HasChildren',
        'INBOX.not.so.deep' => '\\HasNoChildren',
        'INBOX.sub2' => '\\HasChildren',
        'INBOX.sub2.achild' => '\\HasNoChildren',
        'user' => '\\Noselect \\HasChildren',
        'user.bar' => '\\Noselect \\HasChildren',
        'user.bar.Trash' => '\\HasNoChildren',
        'user.foo' => '\\HasChildren',
        'user.foo.really' => '\\Noselect \\HasChildren',
        'user.foo.really.deep' => '\\HasNoChildren',
        'shared stuff' => '\\Noselect \\HasChildren',
        'shared stuff.something' => '\\HasNoChildren',
    });

    xlog $self, "LIST INBOX.*";
    $data = $imaptalk->list("INBOX.", "*");
    $self->_assert_list_data($data, '.', {
        'INBOX.INBOX' => '\\HasChildren',
        'INBOX.INBOX.sub' => '\\HasNoChildren',
        'INBOX.INBOX.very.deep.one' => '\\HasNoChildren',
        'INBOX.Inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.inbox' => '\\HasChildren',
        'INBOX.inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.AEARLY' => '\\HasNoChildren',
        'INBOX.not.so.deep' => '\\HasNoChildren',
        'INBOX.sub2' => '\\HasChildren',
        'INBOX.sub2.achild' => '\\HasNoChildren',
    });

    xlog $self, "LIST INBOX.*%";
    $data = $imaptalk->list("INBOX.", "*%");
    $self->_assert_list_data($data, '.', {
        'INBOX.INBOX' => '\\HasChildren',
        'INBOX.INBOX.sub' => '\\HasNoChildren',
        'INBOX.INBOX.very' => '\\Noselect \\HasChildren',
        'INBOX.INBOX.very.deep' => '\\Noselect \\HasChildren',
        'INBOX.INBOX.very.deep.one' => '\\HasNoChildren',
        'INBOX.Inbox' => '\\Noselect \\HasChildren',
        'INBOX.Inbox.subnobody' => '\\Noselect \\HasChildren',
        'INBOX.Inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.inbox' => '\\HasChildren',
        'INBOX.inbox.subnobody' => '\\Noselect \\HasChildren',
        'INBOX.inbox.subnobody.deep' => '\\HasNoChildren',
        'INBOX.AEARLY' => '\\HasNoChildren',
        'INBOX.not' => '\\Noselect \\HasChildren',
        'INBOX.not.so' => '\\Noselect \\HasChildren',
        'INBOX.not.so.deep' => '\\HasNoChildren',
        'INBOX.sub2' => '\\HasChildren',
        'INBOX.sub2.achild' => '\\HasNoChildren',
    });

    xlog $self, "LIST INBOX.%";
    $data = $imaptalk->list("INBOX.", "%");
    $self->_assert_list_data($data, '.', {
        'INBOX.INBOX' => '\\HasChildren',
        'INBOX.Inbox' => '\\Noselect \\HasChildren',
        'INBOX.inbox' => '\\HasChildren',
        'INBOX.AEARLY' => '\\HasNoChildren',
        'INBOX.not' => '\\Noselect \\HasChildren',
        'INBOX.sub2' => '\\HasChildren',
    });

    xlog $self, "List user.*";
    $data = $imaptalk->list("user.", "*");
    $self->_assert_list_data($data, '.', {
        'user.bar.Trash' => '\\HasNoChildren',
        'user.foo' => '\\HasChildren',
        'user.foo.really.deep' => '\\HasNoChildren',
    });

    xlog $self, "List user.*%";
    $data = $imaptalk->list("user.", "*%");
    $self->_assert_list_data($data, '.', {
        'user.bar' => '\\Noselect \\HasChildren',
        'user.bar.Trash' => '\\HasNoChildren',
        'user.foo' => '\\HasChildren',
        'user.foo.really' => '\\Noselect \\HasChildren',
        'user.foo.really.deep' => '\\HasNoChildren',
    });

    #xlog $self, "List user.%";
    #$data = $imaptalk->list("user.", "%");
    #$self->_assert_list_data($data, '.', {
    #    'user.bar' => '\\Noselect \\HasChildren',
    #    'user.foo' => '\\HasChildren',
    #});

}

# https://tools.ietf.org/html/rfc3501#section-6.3.8
# If the "%" wildcard is the last character of a
# mailbox name argument, matching levels of hierarchy
# are also returned.
sub test_percent_altns
    :UnixHierarchySep :VirtDomains :CrossDomains :AltNamespace :min_version_3_0
{
    my ($self) = @_;

    my $imaptalk = $self->{store}->get_client();
    my $admintalk = $self->{adminstore}->get_client();

    # INBOX needs to exist even if we can't see it
    $admintalk->create('user/bar');

    foreach my $Folder ("user/cassandane/INBOX/sub", "user/cassandane/AEARLY",
                        "user/cassandane/sub2", "user/cassandane/sub2/achild",
                        "user/cassandane/INBOX/very/deep/one",
                        "user/cassandane/not/so/deep",
                        # stuff you can't see
                        "user/cassandane/INBOX",
                        "user/cassandane/inbox",
                        "user/cassandane/inbox/subnobody/deep",
                        "user/cassandane/Inbox/subnobody/deep",
                        # other users
                        "user/bar/Trash",
                        "user/foo",
                        "user/foo/really/deep",
                        # shared
                        "shared stuff/something") {
        $admintalk->create($Folder);
        $admintalk->setacl($Folder, 'cassandane' => 'lrswipkxtecd');
    }

    xlog $self, "List *";
    my $data = $imaptalk->list("", "*");
    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasChildren',
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very/deep/one' => '\\HasNoChildren',
        'AEARLY' => '\\HasNoChildren',
        'not/so/deep' => '\\HasNoChildren',
        'sub2' => '\\HasChildren',
        'sub2/achild' => '\\HasNoChildren',
        'Alt Folders/INBOX' => '\\HasNoChildren \\Noinferiors',
        'Alt Folders/inbox' => '\\HasChildren',
        'Alt Folders/inbox/subnobody/deep' => '\\HasNoChildren',
        'Alt Folders/Inbox/subnobody/deep' => '\\HasNoChildren',
        'Other Users/bar@defdomain/Trash' => '\\HasNoChildren',
        'Other Users/foo@defdomain' => '\\HasChildren',
        'Other Users/foo@defdomain/really/deep' => '\\HasNoChildren',
        'Shared Folders/shared stuff@defdomain/something' => '\\HasNoChildren',
    });

    xlog $self, "List *%";
    $data = $imaptalk->list("", "*%");
    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasChildren',
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very' => '\\Noselect \\HasChildren',
        'INBOX/very/deep' => '\\Noselect \\HasChildren',
        'INBOX/very/deep/one' => '\\HasNoChildren',
        'AEARLY' => '\\HasNoChildren',
        'not' => '\\Noselect \\HasChildren',
        'not/so' => '\\Noselect \\HasChildren',
        'not/so/deep' => '\\HasNoChildren',
        'sub2' => '\\HasChildren',
        'sub2/achild' => '\\HasNoChildren',
        'Alt Folders' => '\\Noselect \\HasChildren',
        'Alt Folders/INBOX' => '\\HasNoChildren \\Noinferiors',
        'Alt Folders/inbox' => '\\HasChildren',
        'Alt Folders/inbox/subnobody' => '\\Noselect \\HasChildren',
        'Alt Folders/inbox/subnobody/deep' => '\\HasNoChildren',
        'Alt Folders/Inbox' => '\\Noselect \\HasChildren',
        'Alt Folders/Inbox/subnobody' => '\\Noselect \\HasChildren',
        'Alt Folders/Inbox/subnobody/deep' => '\\HasNoChildren',
        'Other Users' => '\\Noselect \\HasChildren',
        'Other Users/bar@defdomain' => '\\Noselect \\HasChildren',
        'Other Users/bar@defdomain/Trash' => '\\HasNoChildren',
        'Other Users/foo@defdomain' => '\\HasChildren',
        'Other Users/foo@defdomain/really' => '\\Noselect \\HasChildren',
        'Other Users/foo@defdomain/really/deep' => '\\HasNoChildren',
        'Shared Folders' => '\\Noselect \\HasChildren',
        'Shared Folders/shared stuff@defdomain' => '\\Noselect \\HasChildren',
        'Shared Folders/shared stuff@defdomain/something' => '\\HasNoChildren',
    });

    xlog $self, "List %";
    $data = $imaptalk->list("", "%");
    $self->_assert_list_data($data, '/', {
        'INBOX' => '\\HasChildren',
        'AEARLY' => '\\HasNoChildren',
        'not' => '\\Noselect \\HasChildren',
        'sub2' => '\\HasChildren',
        'Alt Folders' => '\\Noselect \\HasChildren',
        'Other Users' => '\\Noselect \\HasChildren',
        'Shared Folders' => '\\Noselect \\HasChildren',
    });

    # check some partials

    xlog $self, "List INBOX/*";
    $data = $imaptalk->list("INBOX/", "*");
    $self->_assert_list_data($data, '/', {
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very/deep/one' => '\\HasNoChildren',
    });

    xlog $self, "List INBOX/*%";
    $data = $imaptalk->list("INBOX/", "*%");
    $self->_assert_list_data($data, '/', {
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very' => '\\Noselect \\HasChildren',
        'INBOX/very/deep' => '\\Noselect \\HasChildren',
        'INBOX/very/deep/one' => '\\HasNoChildren',
    });

    xlog $self, "List INBOX/%";
    $data = $imaptalk->list("INBOX/", "%");
    $self->_assert_list_data($data, '/', {
        'INBOX/sub' => '\\HasNoChildren',
        'INBOX/very' => '\\Noselect \\HasChildren',
    });

    xlog $self, "List AEARLY/*";
    $data = $imaptalk->list("AEARLY/", "*");
    $self->_assert_list_data($data, '/', {});

    xlog $self, "List AEARLY/*%";
    $data = $imaptalk->list("AEARLY/", "*%");
    $self->_assert_list_data($data, '/', {});

    xlog $self, "List AEARLY/%";
    $data = $imaptalk->list("AEARLY/", "%");
    $self->_assert_list_data($data, '/', {});

    xlog $self, "List sub2/*";
    $data = $imaptalk->list("sub2/", "*");
    $self->_assert_list_data($data, '/', {
        'sub2/achild' => '\\HasNoChildren',
    });

    xlog $self, "List sub2/*%";
    $data = $imaptalk->list("sub2/", "*%");
    $self->_assert_list_data($data, '/', {
        'sub2/achild' => '\\HasNoChildren',
    });

    xlog $self, "List sub2/%";
    $data = $imaptalk->list("sub2/", "%");
    $self->_assert_list_data($data, '/', {
        'sub2/achild' => '\\HasNoChildren',
    });

    xlog $self, "List Alt Folders/*";
    $data = $imaptalk->list("Alt Folders/", "*");
    $self->_assert_list_data($data, '/', {
        'Alt Folders/INBOX' => '\\HasNoChildren \\Noinferiors',
        'Alt Folders/inbox' => '\\HasChildren',
        'Alt Folders/inbox/subnobody/deep' => '\\HasNoChildren',
        'Alt Folders/Inbox/subnobody/deep' => '\\HasNoChildren',
    });

    xlog $self, "List Alt Folders/*%";
    $data = $imaptalk->list("Alt Folders/", "*%");
    $self->_assert_list_data($data, '/', {
        'Alt Folders/INBOX' => '\\HasNoChildren \\Noinferiors',
        'Alt Folders/inbox' => '\\HasChildren',
        'Alt Folders/inbox/subnobody' => '\\Noselect \\HasChildren',
        'Alt Folders/inbox/subnobody/deep' => '\\HasNoChildren',
        'Alt Folders/Inbox' => '\\Noselect \\HasChildren',
        'Alt Folders/Inbox/subnobody' => '\\Noselect \\HasChildren',
        'Alt Folders/Inbox/subnobody/deep' => '\\HasNoChildren',
    });

    xlog $self, "List Alt Folders/%";
    $data = $imaptalk->list("Alt Folders/", "%");
    $self->_assert_list_data($data, '/', {
        'Alt Folders/INBOX' => '\\HasNoChildren \\Noinferiors',
        'Alt Folders/inbox' => '\\HasChildren',
        'Alt Folders/Inbox' => '\\Noselect \\HasChildren',
    });

    xlog $self, "List Other Users";
    $data = $imaptalk->list("", "Other Users");
    $self->_assert_list_data($data, '/', {
        'Other Users' => '\\Noselect \\HasChildren',
    });

    xlog $self, "List Other Users/*";
    $data = $imaptalk->list("Other Users/", "*");
    $self->_assert_list_data($data, '/', {
        'Other Users/bar@defdomain/Trash' => '\\HasNoChildren',
        'Other Users/foo@defdomain' => '\\HasChildren',
        'Other Users/foo@defdomain/really/deep' => '\\HasNoChildren',
    });

    xlog $self, "List Other Users/*%";
    $data = $imaptalk->list("Other Users/", "*%");
    $self->_assert_list_data($data, '/', {
        'Other Users/bar@defdomain' => '\\Noselect \\HasChildren',
        'Other Users/bar@defdomain/Trash' => '\\HasNoChildren',
        'Other Users/foo@defdomain' => '\\HasChildren',
        'Other Users/foo@defdomain/really' => '\\Noselect \\HasChildren',
        'Other Users/foo@defdomain/really/deep' => '\\HasNoChildren',
    });

    xlog $self, "List Other Users/%";
    $data = $imaptalk->list("Other Users/", "%");
    $self->_assert_list_data($data, '/', {
        'Other Users/bar@defdomain' => '\\Noselect \\HasChildren',
        'Other Users/foo@defdomain' => '\\HasChildren',
    });

}

# tests based on rfc 6154 examples:
# https://tools.ietf.org/html/rfc6154#section-5

# "An IMAP server that supports this extension MAY include any or all of the
# following attributes in responses to the non-extended IMAP LIST command."
#
# Cyrus does not (at least, not at the moment), so this test is disabled.
sub bogus_test_rfc6154_ex01_list_non_extended
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => [qw( ToDo Projects Projects/Foo SentMail MyDrafts Trash) ] ],
    ]);

    my $imaptalk = $self->{store}->get_client();
    $imaptalk->setmetadata("SentMail", "/private/specialuse", "\\Sent");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("MyDrafts", "/private/specialuse", "\\Drafts");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("Trash", "/private/specialuse", "\\Trash");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    my $alldata = $imaptalk->list("", "%");

    $self->_assert_list_data($alldata, '/', {
        'INBOX'                 => [qw( \\HasNoChildren )],
        'ToDo'                  => [qw( \\HasNoChildren )],
        'Projects'              => [qw( \\HasChildren )],
        'SentMail'              => [qw( \\Sent \\HasNoChildren )],
        'MyDrafts'              => [qw( \\Drafts \\HasNoChildren )],
        'Trash'                 => [qw( \\Trash \\HasNoChildren )],
    });
}

sub test_rfc6154_ex02a_list_return_special_use
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => [qw( ToDo Projects Projects/Foo SentMail MyDrafts Trash) ] ],
    ]);

    my $imaptalk = $self->{store}->get_client();
    $imaptalk->setmetadata("SentMail", "/private/specialuse", "\\Sent");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("MyDrafts", "/private/specialuse", "\\Drafts");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("Trash", "/private/specialuse", "\\Trash");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    my $alldata = $imaptalk->list("", "%", 'RETURN', [qw( SPECIAL-USE )]);

    $self->_assert_list_data($alldata, '/', {
        'INBOX'                 => [qw( \\HasNoChildren )],
        'ToDo'                  => [qw( \\HasNoChildren )],
        'Projects'              => [qw( \\HasChildren )],
        'SentMail'              => [qw( \\Sent \\HasNoChildren )],
        'MyDrafts'              => [qw( \\Drafts \\HasNoChildren )],
        'Trash'                 => [qw( \\Trash \\HasNoChildren )],
    });
}

sub test_rfc6154_ex02b_list_special_use
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => [qw( ToDo Projects Projects/Foo SentMail MyDrafts Trash) ] ],
    ]);

    my $imaptalk = $self->{store}->get_client();
    $imaptalk->setmetadata("SentMail", "/private/specialuse", "\\Sent");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("MyDrafts", "/private/specialuse", "\\Drafts");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("Trash", "/private/specialuse", "\\Trash");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    my $alldata = $imaptalk->list([qw( SPECIAL-USE )], "", "%");

    $self->_assert_list_data($alldata, '/', {
        'SentMail'              => [qw( \\Sent \\HasNoChildren )],
        'MyDrafts'              => [qw( \\Drafts \\HasNoChildren )],
        'Trash'                 => [qw( \\Trash \\HasNoChildren )],
    });
}

sub test_list_special_use_return_subscribed
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'create' => [qw( ToDo Projects Projects/Foo SentMail MyDrafts Trash) ] ],
        [ 'subscribe' => [qw( SentMail Trash) ] ],
    ]);

    my $imaptalk = $self->{store}->get_client();
    $imaptalk->setmetadata("SentMail", "/private/specialuse", "\\Sent");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("MyDrafts", "/private/specialuse", "\\Drafts");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    $imaptalk->setmetadata("Trash", "/private/specialuse", "\\Trash");
    $self->assert_equals('ok', $imaptalk->get_last_completion_response());

    my $alldata = $imaptalk->list([qw( SPECIAL-USE )], "", "*",
                                  'RETURN', [qw(SUBSCRIBED)]);

    xlog $self, Dumper $alldata;
    $self->_assert_list_data($alldata, '/', {
        'SentMail'              => [qw( \\Sent \\HasNoChildren \\Subscribed )],
        'MyDrafts'              => [qw( \\Drafts \\HasNoChildren )],
        'Trash'                 => [qw( \\Trash \\HasNoChildren \\Subscribed )],
    });

}

sub test_virtdomains_return_subscribed_altns
    :VirtDomains :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->create("user/foo\@example.com");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo\@example.com");
    my $footalk = $foostore->get_client();

    $footalk->create("Drafts");
    $footalk->create("Sent");
    $footalk->create("Trash");

    $footalk->subscribe("INBOX");
    $footalk->subscribe("Drafts");
    $footalk->subscribe("Sent");
    $footalk->subscribe("Trash");

    $footalk->setmetadata("Drafts", "/private/specialuse", "\\Drafts");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    $footalk->setmetadata("Sent", "/private/specialuse", "\\Sent");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    my $specialuse = $footalk->list([qw( SPECIAL-USE )], "", "*",
                                    'RETURN', [qw(SUBSCRIBED)]);

    xlog $self, Dumper $specialuse;
    $self->_assert_list_data($specialuse, '/', {
        'Sent'              => [qw( \\Sent \\HasNoChildren \\Subscribed )],
        'Drafts'            => [qw( \\Drafts \\HasNoChildren  \\Subscribed )],
    });

    $admintalk->create("user/bar\@example.com");
    $admintalk->create("user/bar/shared-folder\@example.com"); # yay bogus domaining
    $admintalk->setacl("user/bar/shared-folder\@example.com",
                       'foo@example.com' => 'lrswipkxtecd');
    $self->assert_equals('ok', $admintalk->get_last_completion_response());

    $footalk->subscribe("Other Users/bar/shared-folder");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    $admintalk->create("another-namespace\@example.com");
    $admintalk->create("another-namespace/folder\@example.com");
    $admintalk->setacl("another-namespace/folder\@example.com",
                       'foo@example.com' => 'lrswipkxtecd');

    $footalk->subscribe("Shared Folders/another-namespace/folder");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    my $alldata = $footalk->list("", "*", 'RETURN', [qw(SUBSCRIBED)]);

    xlog $self, Dumper $alldata;
    $self->_assert_list_data($alldata, '/', {
        'INBOX'         => [qw( \\HasNoChildren \\Subscribed )],
        'Drafts'        => [qw( \\HasNoChildren \\Subscribed )],
        'Sent'          => [qw( \\HasNoChildren \\Subscribed )],
        'Trash'         => [qw( \\HasNoChildren \\Subscribed )],
        'Other Users/bar/shared-folder'
                        => [qw( \\HasNoChildren \\Subscribed )],
        'Shared Folders/another-namespace'
                        => [qw( \\HasChildren )],
        'Shared Folders/another-namespace/folder'
                        => [qw( \\HasNoChildren \\Subscribed )],
    });
}

sub test_virtdomains_return_subscribed_noaltns
    :VirtDomains :UnixHierarchySep
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->create("user/foo\@example.com");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo\@example.com");
    my $footalk = $foostore->get_client();

    $footalk->create("INBOX/Drafts");
    $footalk->create("INBOX/Sent");
    $footalk->create("INBOX/Trash");

    $footalk->subscribe("INBOX");
    $footalk->subscribe("INBOX/Drafts");
    $footalk->subscribe("INBOX/Sent");
    $footalk->subscribe("INBOX/Trash");

    $footalk->setmetadata("INBOX/Drafts", "/private/specialuse", "\\Drafts");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    $footalk->setmetadata("INBOX/Sent", "/private/specialuse", "\\Sent");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    my $specialuse = $footalk->list([qw( SPECIAL-USE )], "", "*",
                                    'RETURN', [qw(SUBSCRIBED)]);

    xlog $self, Dumper $specialuse;
    $self->_assert_list_data($specialuse, '/', {
        'INBOX/Sent'              => [qw( \\Sent \\HasNoChildren \\Subscribed )],
        'INBOX/Drafts'            => [qw( \\Drafts \\HasNoChildren  \\Subscribed )],
    });

    $admintalk->create("user/bar\@example.com");
    $admintalk->create("user/bar/shared-folder\@example.com"); # yay bogus domaining
    $admintalk->setacl("user/bar/shared-folder\@example.com",
                       'foo@example.com' => 'lrswipkxtecd');
    $self->assert_equals('ok', $admintalk->get_last_completion_response());

    $footalk->subscribe("user/bar/shared-folder");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    $admintalk->create("another-namespace\@example.com");
    $admintalk->create("another-namespace/folder\@example.com");
    $admintalk->setacl("another-namespace/folder\@example.com",
                       'foo@example.com' => 'lrswipkxtecd');
    $self->assert_equals('ok', $admintalk->get_last_completion_response());

    $footalk->subscribe("another-namespace/folder");
    $self->assert_equals('ok', $footalk->get_last_completion_response());

    my $alldata = $footalk->list("", "*", 'RETURN', [qw(SUBSCRIBED)]);

    xlog $self, Dumper $alldata;
    $self->_assert_list_data($alldata, '/', {
        'INBOX'         => [qw( \\HasChildren \\Subscribed )],
        'INBOX/Drafts'  => [qw( \\HasNoChildren \\Subscribed )],
        'INBOX/Sent'    => [qw( \\HasNoChildren \\Subscribed )],
        'INBOX/Trash'   => [qw( \\HasNoChildren \\Subscribed )],
        'user/bar/shared-folder' => [qw( \\HasNoChildren \\Subscribed )],
        'another-namespace' => [qw( \\HasChildren ) ],
        'another-namespace/folder' => [qw( \\HasNoChildren \\Subscribed )],
    });
}

sub test_delete_nounsubscribe
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( deltest deltest/sub1 deltest/sub2 )] ],
        [ 'subscribe' => [qw( deltest deltest/sub2 )] ],
        [ 'delete' => 'deltest/sub2' ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $subdata = $imaptalk->list([qw(SUBSCRIBED)], "", "*");

    $self->_assert_list_data($subdata, '/', {
        'INBOX'         => '\\Subscribed',
        'deltest'       => [qw( \\Subscribed )],
        'deltest/sub2'  => [qw( \\NonExistent \\Subscribed )],
    });
}

sub test_delete_unsubscribe
    :UnixHierarchySep :AltNamespace :NoStartInstances :min_version_3_0
{
    my ($self) = @_;

    $self->{instance}->{config}->set('delete_unsubscribe' => 'yes');
    $self->_start_instances();

    $self->_install_test_data([
        [ 'subscribe' => 'INBOX' ],
        [ 'create' => [qw( deltest deltest/sub1 deltest/sub2 )] ],
        [ 'subscribe' => [qw( deltest deltest/sub2 )] ],
        [ 'delete' => 'deltest/sub2' ],
    ]);

    my $imaptalk = $self->{store}->get_client();

    my $subdata = $imaptalk->list([qw(SUBSCRIBED)], "", "*");

    $self->_assert_list_data($subdata, '/', {
        'INBOX'        => '\\Subscribed',
        'deltest'      => '\\Subscribed',
    });
}

sub test_dotuser_gh1875_virt
    :VirtDomains :UnixHierarchySep
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->create("user/foo.bar\@example.com");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo.bar\@example.com");
    my $footalk = $foostore->get_client();

    $footalk->create("INBOX/Drafts");
    $footalk->create("INBOX/Sent");
    $footalk->create("INBOX/Trash");

    my $data = $footalk->list("", "*");

    xlog $self, Dumper $data;
    $self->_assert_list_data($data, '/', {
        'INBOX'             => [qw( \\HasChildren )],
        'INBOX/Sent'        => [qw( \\HasNoChildren )],
        'INBOX/Drafts'      => [qw( \\HasNoChildren )],
        'INBOX/Trash'       => [qw( \\HasNoChildren )],
    });
}

sub test_dotuser_gh1875_novirt
    :UnixHierarchySep
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->create("user/foo.bar");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo.bar");
    my $footalk = $foostore->get_client();

    $footalk->create("INBOX/Drafts");
    $footalk->create("INBOX/Sent");
    $footalk->create("INBOX/Trash");

    my $data = $footalk->list("", "*");

    xlog $self, Dumper $data;
    $self->_assert_list_data($data, '/', {
        'INBOX'             => [qw( \\HasChildren )],
        'INBOX/Sent'        => [qw( \\HasNoChildren )],
        'INBOX/Drafts'      => [qw( \\HasNoChildren )],
        'INBOX/Trash'       => [qw( \\HasNoChildren )],
    });
}

sub test_dotuser_gh1875_virt_altns
    :VirtDomains :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->create("user/foo.bar\@example.com");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo.bar\@example.com");
    my $footalk = $foostore->get_client();

    $footalk->create("Drafts");
    $footalk->create("Sent");
    $footalk->create("Trash");

    my $data = $footalk->list("", "*");

    xlog $self, Dumper $data;
    $self->_assert_list_data($data, '/', {
        'INBOX'       => [qw( \\HasNoChildren )],
        'Sent'        => [qw( \\HasNoChildren )],
        'Drafts'      => [qw( \\HasNoChildren )],
        'Trash'       => [qw( \\HasNoChildren )],
    });
}

sub test_dotuser_gh1875_novirt_altns
    :UnixHierarchySep :AltNamespace
{
    my ($self) = @_;

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->create("user/foo.bar");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo.bar");
    my $footalk = $foostore->get_client();

    $footalk->create("Drafts");
    $footalk->create("Sent");
    $footalk->create("Trash");

    my $data = $footalk->list("", "*");

    xlog $self, Dumper $data;
    $self->_assert_list_data($data, '/', {
        'INBOX'       => [qw( \\HasNoChildren )],
        'Sent'        => [qw( \\HasNoChildren )],
        'Drafts'      => [qw( \\HasNoChildren )],
        'Trash'       => [qw( \\HasNoChildren )],
    });
}

sub test_otherusers_pattern
{
    my ($self) = @_;
    $self->{instance}->create_user("foo");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo");
    my $footalk = $foostore->get_client();

    $footalk->create('INBOX.mytest');
    $self->assert_str_equals('ok', $footalk->get_last_completion_response());
    $footalk->create('INBOX.mytest.mysubtest');
    $self->assert_str_equals('ok', $footalk->get_last_completion_response());

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->setacl("user.foo",
        'cassandane' => 'lrswipkxtecd');
    $self->assert_str_equals('ok',
        $admintalk->get_last_completion_response());
    $admintalk->setacl("user.foo.mytest",
        'cassandane' => 'lrswipkxtecd');
    $self->assert_str_equals('ok',
        $admintalk->get_last_completion_response());
    $admintalk->setacl("user.foo.mytest.mysubtest",
        'cassandane' => 'lrswipkxtecd');
    $self->assert_str_equals('ok',
        $admintalk->get_last_completion_response());

    my $casstalk = $self->{store}->get_client();
    my $data;

    $data = $casstalk->list("", "user.%");
    $self->_assert_list_data($data, '.', {
        'user.foo'                  => [qw( \\HasChildren )],
    });

    $data = $casstalk->list("", "user.foo.%");
    $self->_assert_list_data($data, '.', {
        'user.foo.mytest'           => [qw( \\HasChildren )],
    });

    $data = $casstalk->list("", "user.foo.mytest.%");
    $self->_assert_list_data($data, '.', {
        'user.foo.mytest.mysubtest' => [qw( \\HasNoChildren )],
    });
}

sub test_otherusers_pattern_unixhs
    :UnixHierarchySep
{
    my ($self) = @_;
    $self->{instance}->create_user("foo");

    my $foostore = $self->{instance}->get_service('imap')->create_store(
                        username => "foo");
    my $footalk = $foostore->get_client();

    $footalk->create('INBOX/mytest');
    $self->assert_str_equals('ok', $footalk->get_last_completion_response());
    $footalk->create('INBOX/mytest/mysubtest');
    $self->assert_str_equals('ok', $footalk->get_last_completion_response());

    my $admintalk = $self->{adminstore}->get_client();
    $admintalk->setacl("user/foo",
        'cassandane' => 'lrswipkxtecd');
    $self->assert_str_equals('ok',
        $admintalk->get_last_completion_response());
    $admintalk->setacl("user/foo/mytest",
        'cassandane' => 'lrswipkxtecd');
    $self->assert_str_equals('ok',
        $admintalk->get_last_completion_response());
    $admintalk->setacl("user/foo/mytest/mysubtest",
        'cassandane' => 'lrswipkxtecd');
    $self->assert_str_equals('ok',
        $admintalk->get_last_completion_response());

    my $casstalk = $self->{store}->get_client();
    my $data;

    $data = $casstalk->list("", "user/%");
    $self->_assert_list_data($data, '/', {
        'user/foo'                  => [qw( \\HasChildren )],
    });

    $data = $casstalk->list("", "user/foo/%");
    $self->_assert_list_data($data, '/', {
        'user/foo/mytest'           => [qw( \\HasChildren )],
    });

    $data = $casstalk->list("", "user/foo/mytest/%");
    $self->_assert_list_data($data, '/', {
        'user/foo/mytest/mysubtest' => [qw( \\HasNoChildren )],
    });
}

1;
