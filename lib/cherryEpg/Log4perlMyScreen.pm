package cherryEpg::Log4perlMyScreen;

use 5.024;
use base 'Log::Log4perl::Appender::ScreenColoredLevels';

# Just show the first element of the log array

sub log {
  my ( $self, %params ) = @_;

  my ( $text, $channel, $eit, $info ) = @{ $params{message} };
  $channel //= "-";
  $eit     //= "-";

  my $msg = sprintf( "%-5s %-8s : %s", $params{log4p_level}, $params{log4p_category}, $text );

  my $color = $self->{color}->{ $params{log4p_level} };

  $color = "BLUE" if !$color;

  $msg = Term::ANSIColor::colored( $msg, $color );
  $msg .= ' [' . Term::ANSIColor::colored( $channel, 'BOLD', 'YELLOW' );
  $msg .= '|' . Term::ANSIColor::colored( $eit, 'BOLD', 'BRIGHT_GREEN' ) . ']';
  $msg .= ( $info ? Term::ANSIColor::colored( '*', 'BLUE' ) : '' ) . "\n";

  if ( $self->{stderr} ) {
    print STDERR $msg;
  } else {
    print $msg;
  }
} ## end sub log

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
