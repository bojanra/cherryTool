package cherryEpg::Parser::N1HTML;

use 5.024;
use utf8;
use HTML::Parser;
use Moo;
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.23';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Parse the file and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $parser = HTML::Parser->new( api_version => 3 );

  $parser->{menu}          = {};
  $parser->{desktop}       = undef;
  $parser->{menuField}     = undef;
  $parser->{tabField}      = undef;
  $parser->{timeField}     = undef;
  $parser->{titleField}    = undef;
  $parser->{synopsisField} = undef;
  $parser->{currentEvent}  = undef;
  $parser->{eventList}     = [];
  $parser->{errorList}     = [];

  $parser->handler( start => \&_start, "self, tagname, attr" );
  $parser->handler( text  => \&_text,  "self, text" );
  $parser->handler( end   => \&_end,   "self, tagname" );

  $parser->unbroken_text(1);

  if ( open( my $fh, "<:utf8", $self->{source} ) ) {
    $self->logger->trace( "parse " . $self->{source} );

    my $r = $parser->parse_file($fh);
    close($fh);

    $report->{eventList} = $r->{eventList};
    $report->{errorList} = $r->{errorList};
  } else {
    $report->{errorList} = ["Error opening file: $!"];
  }

  return $report;
} ## end sub parse

sub _start {
  my ( $self, $tagname, $attr ) = @_;

  if ( $tagname eq 'a' && $attr->{href} ) {

    # take number from #tab1
    if ( $attr->{href} =~ m/#menu(\d+)/ ) {
      $self->{menuField} = $1;
    } else {
      $self->{menuField} = undef;
    }
  } ## end if ( $tagname eq 'a' &&...)

  if ( $tagname eq 'div' ) {
    if ( exists $attr->{id} and $attr->{id} =~ m/menu(\d+)/ ) {

      # start of event block
      $self->{tabField} = $1;
    } elsif ( exists $attr->{class} and $attr->{class} eq 'item-hours' ) {

      # this is the event time
      $self->{timeField} = 1;
    } elsif ( exists $attr->{class} and $attr->{class} =~ /desktop-view/ ) {

      # start looking for events
      $self->{desktop} = 1;
    } elsif ( exists $attr->{class} and $attr->{class} =~ /mobile-view/ ) {

      # stop looking for events
      $self->{desktop} = 0;
    } else {
      $self->{timeField} = undef;
    }
  } ## end if ( $tagname eq 'div')

  if ( $tagname eq 'p' and $attr->{class} and $attr->{class} eq 'headline' ) {

    # the title follows
    $self->{titleField} = 1;
  } else {
    $self->{titleField} = 0;
  }

  if ( $tagname eq 'p' and $attr->{class} and $attr->{class} eq 'text' ) {

    # the description follows
    $self->{synopsisField} = 1;
  } else {
    $self->{synopsisField} = 0;
  }
} ## end sub _start

sub _text {
  my ( $self, $text ) = @_;

  $self->{text} = $text;

} ## end sub _text

sub _end {
  my ( $self, $tagname ) = @_;

  return unless $self->{desktop};

  if ( $tagname eq 'span' and $self->{menuField} ) {

    # only trigger on day.month.year
    if ( $self->{text} =~ m/(\d{2}\.\d{2}\.\d{4})/ ) {
      my $t = localtime->strptime( $self->{text}, "%d.%m.%Y" );
      $self->{menu}{ $self->{menuField} } = $t;
    }
  } elsif ( $tagname eq 'p' ) {
    if ( $self->{timeField} ) {
      $self->{currentEvent} = { time => $self->{text} };
    } elsif ( $self->{titleField} ) {
      $self->{currentEvent}{title} = $self->{text};
    } elsif ( $self->{synopsisField} ) {
      $self->{currentEvent}{synopsis} = $self->{text};
      _addEvent($self);
    }
  } ## end elsif ( $tagname eq 'p' )
} ## end sub _end

sub _addEvent {
  my ($self) = @_;

  if ( $self->{currentEvent}{time} !~ m/(\d+):(\d+)/ ) {
    push( @{ $self->{errorList} }, "Incorrect time format [" . $self->{currentEvent}{time} . "]" );
    return;
  }

  my $hour  = $1;
  my $min   = $2;
  my $start = $self->{menu}{ $self->{menuField} };

  $start += ONE_HOUR * $hour + ONE_MINUTE * $min;

  my $event = {
    start    => $start->epoch,
    title    => $self->{currentEvent}{title},
    synopsis => $self->{currentEvent}{synopsis},
  };

  push( @{ $self->{eventList} }, $event );
} ## end sub _addEvent

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
