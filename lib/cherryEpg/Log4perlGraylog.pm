package cherryEpg::Log4perlGraylog;

use 5.010;
use JSON::XS;
use Gzip::Faster;
use Sys::Hostname;

use base 'Log::Log4perl::Appender::Socket';

# Modification to directly log to Graylog server https://www.graylog.org
# always use UDP and compression
#
# Basic configuration:
# log4perl.appender.Graylog              = cherryEpg::Log4perlGraylog
# log4perl.appender.Graylog.PeerAddr     = 192.168.1.74
# log4perl.appender.Graylog.PeerPort     = 12201
# log4perl.appender.Graylog.layout       = NoopLayout
# log4perl.appender.Graylog.warp_message = 0

sub new {
    my ( $class, %params ) = @_;

    $params{Proto} = 'udp';

    my $self = $class->SUPER::new(%params);
    bless $self, $class;

    return $self;
} ## end sub new

sub _to_syslog_priority {
    my ( $self, $level ) = @_;

    my $_table = {
        'TRACE' => 7,
        'DEBUG' => 6,
        'INFO'  => 5,
        'WARN'  => 4,
        'ERROR' => 3,
        'FATAL' => 2
    };
    return $_table->{$level};
} ## end sub _to_syslog_priority


sub log {
    my ( $self, %params ) = @_;

    my ( $text, $channel, $eit ) = @{ $params{message} };

    my $gelf = {
        version       => "1.0",
        host          => hostname,
        short_message => $text,
        service       => $channel,
        eit           => $eit,
        timestamp     => time(),
        level         => $self->_to_syslog_priority( $params{log4p_level} ),
        source        => $params{log4p_category},
    };

    my $json = encode_json($gelf);
    $params{message} = gzip($json);

    return $self->SUPER::log(%params);
} ## end sub log

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
