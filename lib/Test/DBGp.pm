package Test::DBGp;

use strict;
use warnings;

=head1 NAME

Test::DBGp - Test helpers for debuggers using the DBGp protocol

=head1 SYNOPSIS

    use Test::DBGp;

    dbgp_listen();

    # start program under debugger

    dbgp_wait_connection($EXPECTED_APPID);

    dbgp_command_is(['step_into'], {
        reason      => 'ok',
        status      => 'break',
        command     => 'step_into',
    });

=head1 DESCRIPTION

Various helpers to write tests for modules dealing with the DBGp
debugger protocol.

=cut

our $VERSION = '0.06';

use Test::Differences;
use IO::Socket;
use File::Spec::Functions;
use File::Temp;
use Cwd;

require Exporter; *import = \&Exporter::import;

our @EXPORT = qw(
    dbgp_response_cmp
    dbgp_parsed_response_cmp
    dbgp_init_is
    dbgp_command_is

    dbgp_listen
    dbgp_listening_port
    dbgp_listening_path
    dbgp_stop_listening
    dbgp_wait_connection

    dbgp_send_command
);

my ($LISTEN, $CLIENT, $INIT, $SEQ, $PORT, $PATH);

sub dbgp_response_cmp {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    require DBGp::Client::Parser;

    my ($xml, $expected) = @_;
    my $res = DBGp::Client::Parser::parse($xml);
    my $cmp = _extract_command_data($res, $expected);

    eq_or_diff($cmp, $expected);
}

sub dbgp_parsed_response_cmp {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my ($res, $expected) = @_;
    my $cmp = _extract_command_data($res, $expected);

    eq_or_diff($cmp, $expected);
}

sub _extract_command_data {
    my ($res, $expected) = @_;

    if (!ref $expected) {
        return $res;
    } elsif (ref $expected eq 'HASH') {
        return $res if !defined $res;
        return {
            map {
                $_ => _extract_command_data($res->$_, $expected->{$_})
            } keys %$expected
        };
    } elsif (ref $expected eq 'ARRAY') {
        return $res if ref $res ne 'ARRAY';
        return [
            ( map {
                _extract_command_data($res->[$_], $expected->[$_])
            } 0 .. $#$expected ),
            ( ("<unexpected item>") x ($#$res - $#$expected) ),
        ];
    } else {
        die "Can't extract ", ref $expected, "value";
    }
}

sub dbgp_listen {
    if ($^O eq 'MSWin32') {
        dbgp_listen_tcp();
    } else {
        dbgp_listen_unix();
    }
}

sub dbgp_listen_tcp {
    return if $LISTEN;

    for my $port (!$PORT ? (17000 .. 19000) : ($PORT)) {
        $LISTEN = IO::Socket::INET->new(
            Listen    => 1,
            LocalAddr => '127.0.0.1',
            LocalPort => $port,
            Proto     => 'tcp',
            Timeout   => 2,
        );
        next unless $LISTEN;

        $PORT = $port;
        $PATH = undef;
        last;
    }

    die "Unable to open a listening socket in the 17000 - 19000 port range"
        unless $LISTEN;
}

sub dbgp_listen_unix {
    return if $LISTEN;

    my $path = $PATH;
    if (!$path) {
        $path = File::Spec::Functions::rel2abs('dbgp.sock', Cwd::getcwd());

        if (length($path) >= 90) { # arbitrary, should be low enough
            my $tempdir = File::Temp::tempdir(CLEANUP => 1);
            $path = File::Spec::Functions::rel2abs('dbgp.sock', $tempdir);
        }
    }
    unlink $path if -S $path;
    return if -e $path;

    $LISTEN = IO::Socket::UNIX->new(
        Local   => $path,
        Listen  => 1,
    );
    $PORT = undef;
    $PATH = $path;

    die "Unable to open a listening socket on '$path'"
        unless $LISTEN;
}

sub dbgp_stop_listening {
    close $LISTEN;
    $LISTEN = undef;
}

sub dbgp_listening_port { $PORT }
sub dbgp_listening_path { $PATH }

sub dbgp_wait_connection {
    my ($pid, $reject) = @_;
    my $conn = $LISTEN->accept;

    die "Did not receive any connection from the debugged program: ", $LISTEN->error
        unless $conn;

    if ($reject) {
        close $conn;
        return;
    }

    require DBGp::Client::Stream;
    require DBGp::Client::Parser;

    $CLIENT = DBGp::Client::Stream->new(socket => $conn);

    # consume initialization line
    $INIT = DBGp::Client::Parser::parse($CLIENT->get_line);

    die "We got connected with the wrong debugged program"
        if $INIT->appid != $pid || $INIT->language ne 'Perl';
}

sub dbgp_send_command {
    my ($command, @args) = @_;

    $CLIENT->put_line($command, '-i', ++$SEQ, @args);
    my $res = DBGp::Client::Parser::parse($CLIENT->get_line);

    die 'Mismatched transaction IDs: got ', $res->transaction_id,
            ' expected ', $SEQ
        if $res && $res->transaction_id != $SEQ;

    return $res;
}

sub dbgp_init_is {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my ($expected) = @_;
    my $cmp = _extract_command_data($INIT, $expected);

    eq_or_diff($cmp, $expected);
}

sub dbgp_command_is {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my ($command, $expected) = @_;
    my $res = dbgp_send_command(@$command);
    my $cmp = _extract_command_data($res, $expected);

    eq_or_diff($cmp, $expected);
}

1;

__END__

=head1 AUTHOR

Mattia Barbon <mbarbon@cpan.org>

=head1 LICENSE

Copyright (c) 2015-2016 Mattia Barbon. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
