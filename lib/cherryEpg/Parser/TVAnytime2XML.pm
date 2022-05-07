package cherryEpg::Parser::TVAnytime2XML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.10';

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

    my $handler = TVAnytime2XMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package TVAnytime2XMLHandler;
use strict;
use warnings;
use Time::Piece;
use Time::Seconds;
use Carp qw( croak );

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

    if ( $element->{Name} eq 'ProgramInformation' ) {

        # take just the id
        if ( $element->{Attributes}{programId} ) {
            $self->{programId}          = $element->{Attributes}{programId};
            $self->{currentProgramInfo} = {};
        }
    } elsif ( $element->{Name} eq 'ScheduleEvent' ) {
        $self->{currentEvent} = {};
    } elsif ( $element->{Name} eq 'Program' ) {
        if ( $element->{Attributes}{crid} ) {
            $self->{currentEvent}{id} = $element->{Attributes}{crid};
        }
    }

    if ( $element->{Attributes}{type} ) {
        $self->{type} = $element->{Attributes}{type};
    } else {
        $self->{type} = undef;
    }

    if ( $element->{Attributes}{'xml:lang'} ) {
        $self->{lang} = $element->{Attributes}{'xml:lang'};
    } else {
        $self->{lang} = undef;
    }

    if ( $element->{Attributes}{length} ) {
        $self->{length} = $element->{Attributes}{length};
    } else {
        $self->{length} = undef;
    }

    $self->{currentData} = "";
} ## end sub start_element

sub characters {
    my ( $self, $element ) = @_;

    $self->{currentData} .= $element->{Data};
}

sub decodeTime {
    my ( $self, $time ) = @_;

    if ( $time =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+\d{2}):(\d{2})/ ) {

        # 2020-07-20T05:45:00+01:00 -> 2020-07-20T05:45:00+0100
        # remove last doublepoint
        return Time::Piece->strptime( $1 . $2, "%Y-%m-%dT%H:%M:%S%z" )->epoch;
    } elsif ( $time =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z/ ) {

        # 2020-08-31T07:30:00Z
        return Time::Piece->strptime( $1, "%Y-%m-%dT%H:%M:%S" )->epoch;
    } else {
        return;
    }
} ## end sub decodeTime

sub end_element {
    my ( $self, $element ) = @_;
    my $value = $self->{currentData};

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
        /title/i && do {
            if ( $self->{type} ) {
                if ( $self->{type} eq 'main' ) {
                    $self->{currentProgramInfo}{title} = $value;
                } elsif ( $self->{type} eq 'episodeTitle' ) {
                    $self->{currentProgramInfo}{subtitle} = $value;
                }
            } ## end if ( $self->{type} )
            return;
        };
        /synopsis/i && do {
            $self->{currentProgramInfo}{synopsis} = $value;
            return;
        };
        /name/i && do {
            $self->{Name} = $value;
            return;
        };
        /ParentalGuidance/i && do {

            if ( $self->{Name} =~ /^\d+$/ ) {
                $self->{currentProgramInfo}{parental_rating} = $self->{Name};
            }
            return;
        };
        /ProgramInformation/ && do {
            my $id = $self->{programId};
            $self->{programInfo}{$id} = {};

            # copy all info to the hash
            foreach ( keys %{ $self->{currentProgramInfo} } ) {
                $self->{programInfo}{$id}{$_} = $self->{currentProgramInfo}{$_};
            }
            return;
        };
        /ScheduleEvent/ && do {
            my $id = $self->{currentEvent}{id};
            delete $self->{currentEvent}{id};

            # lookup ProgramInformation by $id
            if ( exists $self->{programInfo}{$id} ) {
                foreach ( keys %{ $self->{programInfo}{$id} } ) {
                    $self->{currentEvent}{$_} = $self->{programInfo}{$id}{$_};
                }
                $self->addEvent();
            } else {
                $self->_error( "Mapping ScheduleEvent->ProgramInformation failed" . $self->{linecount} );
            }
            return;
        };
        /PublishedEndTime/ && do {
            $self->{currentEvent}{stop} = $self->decodeTime($value);
            return;
        };
        /PublishedStartTime/ && do {
            $self->{currentEvent}{start} = $self->decodeTime($value);
            return;
        };
    } ## end SWITCH: for ( $element->{Name} )
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

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" ) unless defined $event->{start};
    push( @missing, "stop" )  unless defined $event->{stop};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
        $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    # push to final array
    push( @{ $self->{eventList} }, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
