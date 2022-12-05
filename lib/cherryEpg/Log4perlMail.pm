package cherryEpg::Log4perlMail;

our @ISA = qw(Log::Log4perl::Appender);

# Send notifications also over mail using SMTPS
#
# For detailed information see
# Net::SMTPS which is a improved version of
# Net::SMTP which in a subclass of
# Net::Cmd (depending on avaibility) of IO::Socket::IP, IO::Socket::INET6 or IO::Socket::INET
#
# Basic configuration for GMAIL
# log4perl.logger                     = INFO, Mail
# log4perl.oneMessagePerAppender      = 1
# log4perl.appender.Mail              = cherryEpg::Log4perlMail
# log4perl.appender.Mail.Threshold    = WARN
# log4perl.appender.Mail.layout       = Log::Log4perl::Layout::NoopLayout
# log4perl.appender.Mail.Host         = smtp.gmail.com:587
# log4perl.appender.Mail.auth         = username:password
# log4perl.appender.Mail.doSSL        = 'starttls',
# log4perl.appender.Mail.from         = sender_mail@gmail.com
# log4perl.appender.Mail.to           = name <recipient_mail@mail.com>
# log4perl.appender.Mail.cc           = alternative_recipient_mail@com
# log4perl.appender.Mail.Debug        = 0
# log4perl.appender.Mail.warp_message = 0

use 5.024;
use utf8;
use Carp;
use Net::SMTPS;
use strict;
use Sys::Hostname;
use Time::Piece;
use warnings;

sub new {
    my ( $class, @options ) = @_;

    my $self = {@options};
    bless $self, $class;

    return $self;
} ## end sub new

sub log {
    my ( $self, %params ) = @_;

    my ( $text, $channel, $eit, $info ) = @{ $params{'message'} };

    my $subject = "$params{'log4p_level'} from $params{'log4p_category'} on " . hostname . "\n";
    my $content = "";
    $content .= "cherryEpg on host " . hostname . " notification:\n";
    $content .= "* $text" . ( $channel ? " (SID=$channel)" : "" ) . "\n";
    if ($info) {
        if ( ref($info) eq 'ARRAY' ) {
            foreach (@$info) {
                $content .= "  - $_\n";
            }
        } elsif ( ref($info) eq 'HASH' && exists $info->{errorList} ) {
            my $list = $info->{errorList};
            foreach my $error (@$list) {
                if ( ref($error) eq '' ) {
                    $content .= "  - " . $error . "\n";
                } elsif ( ref($error) eq 'HASH' && exists $error->{error} && ref( $error->{error} ) eq 'ARRAY' ) {
                    $content .= "  - " . join( ', ', @{ $error->{error} } ) . "\n";
                }
            } ## end foreach my $error (@$list)
        } ## end elsif ( ref($info) eq 'HASH'...)
    } ## end if ($info)

    $content .= "\n# " . localtime()->datetime;

    my $smtp = Net::SMTPS->new(%$self) or return carp " log4perl : failed connecting to the SMTP server ";

    # split the username:password and run auth only with usernames defined and not space
    my ( $username, $password ) = split( /:/, $self->{auth} );
    if ( $username && $username !~ /^ +/ ) {
        $smtp->auth( $username, $password // '' );
    }

    foreach my $t ( 'from', 'to', 'cc', 'bcc' ) {
        if ( exists $self->{$t} ) {
            my $s = $self->{$t};
            $s = $1 if $s =~ /.*<(.+@.+)>/;

            if ( $t eq 'from' ) {
                $smtp->mail($s);
            } else {
                $smtp->$t($s);
            }
        } ## end if ( exists $self->{$t...})
    } ## end foreach my $t ( 'from', 'to'...)

    $smtp->data;

    $smtp->datasend("From: $self->{from}\n");
    $smtp->datasend("To: $self->{to}\n");
    $smtp->datasend("Cc: $self->{cc}\n")   if exists( $self->{cc} )  && $self->{cc} ne '';
    $smtp->datasend("Bcc: $self->{bcc}\n") if exists( $self->{bcc} ) && $self->{bcc} ne '';
    $smtp->datasend("Subject: $subject");
    $smtp->datasend("\n");
    $smtp->datasend($content);
    $smtp->dataend;
    $smtp->quit;
} ## end sub log

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
