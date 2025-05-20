package cherryEpg::Parser::TVListingXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.28';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $handler = TVListingXMLHandler->new();
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  $parser->parse( Source => { SystemId => $self->{source} } );

  return $report;
} ## end sub parse

package TVListingXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;
use Carp qw( croak );

my %content = (
  cartoon     => 0x55,
  documentary => 0x23,
  movie       => 0x10,
  news        => 0x20,
  show        => 0x30,
  sports      => 0x40
);

# First go over ProgramInformationTable and store the elements (event) descriptions.
# Then go over Schedule and map event elements to start/stop data.

sub new {
  my $this  = shift;
  my $class = ref($this) || $this;
  my $self  = {};

  bless( $self, $class );
  return $self;
} ## end sub new

sub start_document {
  my ($self) = @_;

  # temporary program info hash
  $self->{programInfo} = {};

  # this will be the events
  $self->{eventList} = [];

  # and the possible error list
  $self->{errorList} = [];
} ## end sub start_document

sub end_document {
  my ( $self, $element ) = @_;

  $self->{report}            = $self->{'_parser'}->{output};
  $self->{report}{eventList} = $self->{eventList};
  $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} eq 'Event' ) {

    my $event = {};
    $event->{start} = try {
      if ( exists $element->{Attributes}{beginTime} ) {
        Time::Piece->strptime( $element->{Attributes}{beginTime}, "%Y%m%d%H%M%S" )->epoch;
      } else {
        return undef;
      }
    };
    $event->{duration}    = exists $element->{Attributes}{duration} ? $element->{Attributes}{duration} : undef;
    $self->{currentEvent} = $event;
  } elsif ( $element->{Name} eq 'ExtendedInfo' && exists $element->{Attributes}{name} ) {

    $self->{currentEvent}{nameAttribute} = $element->{Attributes}{name};
  } elsif ( $element->{Name} eq 'User' ) {

    $self->{currentEvent}{nibble} = try {
      if ( exists $element->{Attributes}{nibble1}
        && exists $element->{Attributes}{nibble2} ) {
        return $element->{Attributes}{nibble1} << 4 | $element->{Attributes}{nibble2};
      }
    };
  } else {

    delete $self->{currentEvent}{nameAttribute};
  }

  $self->{currentData} = "";
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;

  $self->{currentData} .= $element->{Data};
}

sub end_element {
  my ( $self, $element ) = @_;
  my $value = $self->{currentData};
  my $event = $self->{currentEvent};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

  if ( $element->{Name} eq 'Event' ) {

    $self->addEvent();
  } elsif ( $element->{Name} eq 'Name' ) {

    $event->{title} = $value;
  } elsif ( $element->{Name} eq 'ShortDescription' ) {

    $event->{short} = $value;
  } elsif ( $element->{Name} eq 'Description' ) {

    $event->{synopsis} = $value;
  } elsif ( $element->{Name} eq 'ParentalRating' ) {

    if ( $value == 7 || $value == 12 || $value == 16 || $value == 18 ) {
      $event->{country_code}    = 'ESP';
      $event->{parental_rating} = $value;
    }
  } elsif ( $element->{Name} eq 'ExtendedInfo' ) {

    my $name = $self->{currentEvent}{nameAttribute};
    $self->{currentEvent}{ExtendedInfo}{$name} = $value;
  }

  return;
} ## end sub end_element

sub set_document_locator {
  my ( $self, $params ) = @_;
  $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
  my $self = shift;

  push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

sub addEvent {
  my $self  = shift;
  my $event = $self->{currentEvent};

  # try to get the best title
  if ( !$event->{title} ) {
    if ( $event->{ExtendedInfo}{OriginalEpisodeName} ) {
      $event->{title} = $event->{ExtendedInfo}{OriginalEpisodeName};
    } elsif ( $event->{ExtendedInfo}{EpisodeName} ) {
      $event->{title} = $event->{ExtendedInfo}{EpisodeName};
    }
  } ## end if ( !$event->{title} )

  # try to do the best subtitle
  if ( !$event->{subtitle} && $event->{ExtendedInfo} ) {

    my $ext = $event->{ExtendedInfo};
    $event->{subtitle} = try {
      return $ext->{Nationality} . " " . $ext->{Year} . " - " . $ext->{Cycle} . "/" . $ext->{EpisodeNumber};
    };
  } ## end if ( !$event->{subtitle...})

  delete $event->{ExtendedInfo};
  delete $event->{nameAttribute};

  # check if all event data is complete and valid
  my @missing;
  push( @missing, "start" )    unless defined $event->{start};
  push( @missing, "duration" ) unless defined $event->{duration};
  push( @missing, "title" )    unless defined $event->{title};

  if ( scalar @missing > 0 ) {
    $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
    return;
  }

  # push to final array
  push( @{ $self->{eventList} }, $event );

  return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
__END__

      <Event beginTime="20250314075500" duration="2700">
        <EpgProduction>
          <EpgText language="">
            <Name/>
            <Description/>
            <ExtendedInfo name="EpisodeName"/>
            <ExtendedInfo name="OriginalEpisodeName">Ultimate Cargo Ship</ExtendedInfo>
            <ExtendedInfo name="EpisodeNumber">2</ExtendedInfo>
            <ExtendedInfo name="Cycle">1</ExtendedInfo>
            <ExtendedInfo name="Director"/>
            <ExtendedInfo name="Year">2019</ExtendedInfo>
            <ExtendedInfo name="Nationality">GBR</ExtendedInfo>
          </EpgText>
          <ParentalRating>0</ParentalRating>
          <StarRating>0</StarRating>
          <AudioInfo>
            <StereoFlag>1</StereoFlag>
            <DolbyDigitalFlag>0</DolbyDigitalFlag>
            <SurroundSoundFlag>0</SurroundSoundFlag>
            <AudioDescription>N</AudioDescription>
          </AudioInfo>
          <VideoInfo>
            <Color>0</Color>
            <ScreenFormat>1</ScreenFormat>
          </VideoInfo>
          <DvbContent>
            <User nibble1="5" nibble2="5"/>
          </DvbContent>
        </EpgProduction>
      </Event>
