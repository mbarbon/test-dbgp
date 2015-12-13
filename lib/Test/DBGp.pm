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

our $VERSION = '0.01';

use Test::Differences;
use IO::Socket;

require Exporter; *import = \&Exporter::import;

our @EXPORT = qw(
    dbgp_response_cmp
    dbgp_init_is
    dbgp_command_is

    dbgp_listen
    dbgp_listening_port
    dbgp_stop_listening
    dbgp_wait_connection

    dbgp_send_command
);

my ($LISTEN, $CLIENT, $INIT, $SEQ, $PORT);

sub dbgp_response_cmp {
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    require DBGp::Client::Parser;

    my ($xml, $expected) = @_;
    my $res = DBGp::Client::Parser::parse($xml);
    my $cmp = _extract_command_data($res, $expected);

    eq_or_diff($cmp, $expected);
}

sub _extract_command_data {
    my ($res, $expected) = @_;

    if (!ref $expected) {
        return $res;
    } elsif (ref $expected eq 'HASH') {
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
        last;
    }

    die "Unable to open a listening socket in the 17000 - 19000 port range"
        unless $LISTEN;
}

sub dbgp_stop_listening {
    close $LISTEN;
    $LISTEN = undef;
}

sub dbgp_listening_port { $PORT }

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

Copyright (c) 2015 Mattia Barbon. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
