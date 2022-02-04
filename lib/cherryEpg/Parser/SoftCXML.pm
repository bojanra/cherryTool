package cherryEpg::Parser::SoftCXML;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.13';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => hash of arrays of events found

The XML file can contain multiple programme/service schedules.

Please be carefull programme = channel here.

When multiple programme are defined $parserOption should contain a key value e.g.
channel => "110" to select a programme.
If there is only a single programmee defined in the file no channel option is required.

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    my $handler = SoftCXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    # now we have multiple channels, let's select the requested one
    if ( defined $option ) {

        # select by parser option
        if ( exists $report->{channel}{$option} ) {
            $report->{eventList} = $report->{channel}{$option}{eventList};
            $report->{option}    = $option;
            delete $report->{channel};
        } else {
            push( @{ $report->{errorList} }, "incorrect channel selection" );
        }
    } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 1 ) {

        # if there is just a single channel we asume it's the right one
        my $channel = ( values( %{ $report->{channel} } ) )[0];
        $report->{eventList} = $channel->{eventList};
        delete $report->{channel};
    } elsif ( scalar( keys( %{ $report->{channel} } ) ) == 0 ) {
        push( @{ $report->{errorList} }, "no valid events" );
    } else {
        push( @{ $report->{errorList} }, "missing channel selection after parser" );
    }

    return $report;
} ## end sub parse

package SoftCXMLHandler;
use Moo;
use utf8;
use Time::Piece;
use Try::Tiny;

sub start_document {
    my ($self) = @_;

    # here we will store all program hashes
    $self->{channel} = {};

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ( $self, $element ) = @_;

    $self->{report} = $self->{'_parser'}->{output};

    # return all built program lists
    $self->{report}{channel}   = $self->{channel};
    $self->{report}{errorList} = $self->{errorList};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} =~ /Service/ ) {
        $self->{service} = $element->{Attributes}{id};
    } elsif ( $element->{Name} eq "Event" ) {
        $self->{currentEvent} = {};
    } elsif ( $element->{Name} eq "ShortEventDescription" ) {
        $self->{currentEvent}{description} = 'short';
    } elsif ( $element->{Name} eq "LongEventDescription" ) {
        $self->{currentEvent}{description} = 'long';
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

    $value =~ s/^\s+//;
    $value =~ s/\s+$//;

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

    for ( $element->{Name} ) {
        $_ eq "Event" && do {

            # add event to the list
            $self->addEvent();
            return;
        };
        $_ eq "Name" && do {
            if ( exists $self->{currentEvent}{description} ) {
                my $d = $self->{currentEvent}{description};
                $event->{$d}{name} = $value;
            }
            return;
        };
        $_ eq "Description" && do {
            if ( exists $self->{currentEvent}{description} ) {
                my $d = $self->{currentEvent}{description};
                $event->{$d}{description} = $value;
            }
            return;
        };
        /DurationHour/ && do {
            return                  if $value eq '';
            $event->{hour} = $value if $value =~ m/\d+/;
            return;
        };
        /DurationMin/ && do {
            return                 if $value eq '';
            $event->{min} = $value if $value =~ m/\d+/;
            return;
        };
        /DurationSec/ && do {
            return                 if $value eq '';
            $event->{sec} = $value if $value =~ m/\d+/;
            return;
        };
        /StartDate/ && do {
            return                  if $value eq '';
            $event->{date} = $value if $value =~ m/\d{4}-\d{2}-\d{2}/;
            return;
        };
        /StartTime/ && do {
            return                  if $value eq '';
            $event->{time} = $value if $value =~ m/\d{2}:\d{2}:\d{2}/;
            return;
        };
    } ## end for ( $element->{Name} )
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
    my $self     = shift;
    my $rawEvent = $self->{currentEvent};

    # compact data
    my $event = {};

    $event->{start} = try {
        my $m = $rawEvent->{date} . 'T' . $rawEvent->{time};
        localtime->strptime( $m, "%Y-%m-%dT%H:%M:%S%z" )->epoch;
    };
    $event->{duration} = try {
        ( ( 60 * $rawEvent->{hour} + $rawEvent->{min} ) * 60 ) + $rawEvent->{sec};
    };
    $event->{title}    = try { $rawEvent->{short}{name}; };
    $event->{subtitle} = try {
        '' if $rawEvent->{short}{name} eq $rawEvent->{short}{description};
    };
    $event->{synopsis} = try {
        my $name        = $rawEvent->{long}{name}        // '';
        my $description = $rawEvent->{long}{description} // '';
        return $description if $description =~ m|^$name|;
        return $name        if $description eq '';
        return $name . ' ' . $description;
    };
    delete $event->{synopsis} if $event->{synopsis} eq $event->{title};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" )    unless defined $event->{start};
    push( @missing, "duration" ) unless defined $event->{duration};

    if ( scalar @missing > 0 ) {
        $self->_error( "missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    my $service = $self->{service};

    # push to final array
    push( @{ $self->{channel}{$service}{eventList} }, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
