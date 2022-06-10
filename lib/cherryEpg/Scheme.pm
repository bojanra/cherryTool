package cherryEpg::Scheme;

use 5.010;
use utf8;
use Moo;
use strictures 2;
no warnings 'experimental';
use Try::Tiny;
use Path::Class;
use File::Basename;
use Log::Log4perl qw(get_logger);
use YAML::XS;
use Spreadsheet::Read qw( row ReadData);
use Data::Validate::IP qw(is_ipv4);
use Sys::Hostname;
use File::stat;
use Time::Piece;
use Gzip::Faster;
use Digest::MD5 qw(md5_base64);
use Encode qw(encode_utf8);
use cherryEpg;
use cherryEpg::Table;
use cherryEpg::Player;
use POSIX qw(ceil);
use open ':std', ':encoding(utf8)';

my $archiveExtension = '.yaml.gz';

my $logger = get_logger('system');

has 'verbose' => (
    is      => 'ro',
    default => 0
);

has 'cherry' => ( is => 'lazy', );

sub _build_cherry {
    my ($self) = @_;

    return cherryEpg->instance( verbose => $self->verbose );
}

=head3 readXLS( $file )

Read the $file in XLS format and do basic validation.
Return raw data hash.

=cut

sub readXLS {
    my ( $self, $file ) = @_;

    # raw scheme data from imported file
    my $raw = {
        channel      => [],
        eit          => {},
        rule         => [],
        target       => undef,
        source       => {},
        countIgnored => 0,
        extendedSID  => 0,
        nomesh       => 0,
        noautorule   => 0,
        salt         => hostname . localtime,
    };

    $self->{raw}       = $raw;
    $self->{errorList} = [];
    $self->{scheme}    = {};

    if ( !-e $file ) {
        $self->error("Compiling failed. Cannot open input file [$file]");
        return $raw;
    }

    my $isServiceSheet = 0;
    my $isEitSheet     = 0;

    my $eBook = ReadData( $file, parser => "xls" );

    my $allSheets = $eBook->[0]{sheet};

    # parse CONF sheet first
    if ( exists $allSheets->{CONF} ) {
        $self->parseConf( $eBook, 'CONF' );
    }

    foreach my $sheetName ( keys %$allSheets ) {

        next if $sheetName eq 'CONF';

        for ($sheetName) {
            /^SERVICE$/ && do {
                $isServiceSheet = 1;
                $self->parseService( $eBook, $sheetName );
                last;
            };
            /^EIT/ && do {
                $isEitSheet = 1;
                $self->parseEIT( $eBook, $sheetName );
                last;
            };
            /^RULE$/ && do {
                $self->parseRule( $eBook, $sheetName );
                last;
            };
        } ## end for ($sheetName)
    } ## end foreach my $sheetName ( keys...)

    $self->error("Missing [SERVICE] sheet") if !$isServiceSheet;
    $self->error("Missing [EIT] sheet")     if !$isEitSheet;

    # read input file as binary and insert in report
    my $blob = try {
        local $/;
        open( my $fh, '<:raw', $file ) || return;
        <$fh>;
    };

    # extract just filename
    my ($filename) = fileparse($file);

    my $t = gmtime( stat($file)->mtime );

    $raw->{source} = {
        filename    => $filename,
        blob        => $blob,
        mtime       => $t->datetime,
        description => $self->{raw}{description} // '',
    };

    return $raw;
} ## end sub readXLS

=head3 push()

Push/load current scheme to database.

=cut

sub push {
    my ($self) = @_;

    my $scheme   = $self->{scheme};
    my $filename = $scheme->{source}{filename};

    # load to db
    my ( $success, $error ) = $self->cherry->epg->import($scheme);

    # generate&play tables
    my $psigen = cherryEpg::Table->new();
    my $player = cherryEpg::Player->new();
    foreach my $name ( sort keys $scheme->{table}->%* ) {
        my $table = $scheme->{table}{$name};
        my $chunk = $psigen->build($table);

        if ($chunk) {
            if ( $player->arm( $name, $table->{'..'}, \$chunk, undef ) && $player->play($name) ) {
                $logger->trace("playing $table->{table} - $name");
            } else {
                $logger->error("playing $table->{table} - $name");
            }
        } else {
            $logger->error("building $table->{table} - $name");
        }
    } ## end foreach my $name ( sort keys...)

    if ( scalar @$error == 0 ) {
        $logger->info( "import [$filename] with " . scalar(@$success) . " elements", undef, undef, $scheme );
    } else {
        $logger->warn( "import [$filename] with " . scalar(@$success) . " elements - " . scalar(@$error) . " errors",
            undef, undef, $scheme );
    }
    return ( $success, $error );
} ## end sub push

=head3 pull()

Pull/read scheme from database.

=cut

sub pull {
    my ( $self, $filename ) = @_;

    # get struct
    my $exported = $self->cherry->epg->export();

    $self->{raw}       = {};
    $self->{errorList} = [];
    $self->{scheme}    = $exported;

    # all schemes from db are valid
    $self->{scheme}{isValid} = 1;

    $logger->trace( "exporting scheme from database", undef, undef, $exported );

    return $exported;
} ## end sub pull

=head3 Import( $file )
=head3 Import( $string )

Import scheme from YAML $file or $string.
Return reference to $scheme

=cut

sub Import {
    my ( $self, $arg ) = @_;

    $self->{raw}       = {};
    $self->{errorList} = [];
    $self->{scheme}    = {};

    my $scheme;

    if ( $arg =~ m/^--/s ) {

        # we have a yaml string
        $scheme = YAML::XS::Load($arg);
    } else {

        # or a path/file
        my $file = $arg;

        if ( $file =~ /\.gz$/ ) {
            $scheme = try {
                my $content = gunzip_file($file);
                return YAML::XS::Load($content);
            };
        } else {
            $scheme = try {

                YAML::XS::LoadFile($file);
            };

        } ## end else [ if ( $file =~ /\.gz$/ )]
    } ## end else [ if ( $arg =~ m/^--/s )]

    return unless $scheme;

    $self->{scheme} = $scheme;

    return $scheme;
} ## end sub Import

=head3 export( $file)
=head3 export( )

Write scheme to $file in yaml format or gzip if $flag is set and return 1 on success.
Return scheme data as string if no filename defined.

=cut

sub export {
    my ( $self, $file, $gzip ) = @_;

    $YAML::XS::QuoteNumericStrings = 0;

    $gzip = 1 if $file && $file =~ /\.gz$/;

    if ($file) {
        my $result;
        if ($gzip) {
            return try {
                gzip_to_file( YAML::XS::Dump( $self->{scheme} ), $file );
            };
        } else {
            return YAML::XS::DumpFile( $file, $self->{scheme} );
        }
    } else {
        return YAML::XS::Dump( $self->{scheme} );
    }
} ## end sub export

=head3 parseService(  )

Columns in SERVICE sheet:
serviceName, tsid, sid, onid, maxsegments, codepage, language, grabber->source, grabber->update, parser, parser option, XMLTV ID,  comment
0            1     2    3     4            5         6         7                8                9       10             11         12

Ignore row with text IGNORESERVICE anywhere

=cut

sub parseService {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my $country = "";
        my @field   = Spreadsheet::Read::row( $sheet, $rowCounter );
        if ( scalar(@field) < 11 ) {
            $self->error("Not enough columns in row [$sheetName:$rowCounter]");
            next;
        }

        # skip column name row
        next if $rowCounter == 1;

        my $skipRow = 0;

        # remove leading and trailing spaces, ', "
        foreach (@field) {
            next if !defined;
            s/^[\s'"]+//;
            s/[\s'"]+$//;

            # ignore row if somewhere IGNORESERVICE
            if (m/IGNORESERVICE/) {
                $skipRow = 1;
            }
        } ## end foreach (@field)

        if ($skipRow) {
            $raw->{countIgnored} += 1;
            next;
        }

        # check for name
        if ( !$field[0] || $field[0] eq "" ) {
            $self->error("Service name missing in row [$sheetName:$rowCounter]");
            next;
        }

        # check for parser
        if ( !$field[9] || $field[9] eq "" ) {
            $self->error("No parser in row [$sheetName:$rowCounter]");
            next;
        }

        # tsid, sid and onid must be numbers
        if (  !$field[1]
            || $field[1] !~ m|^\d+$|
            || !$field[2]
            || $field[2] !~ m|^\d+$|
            || !$field[3]
            || $field[3] !~ m|^\d+$| ) {
            $self->error("TSID, SID or ONID are not numbers in row [$sheetName:$rowCounter]");
            next;
        } ## end if ( !$field[1] || $field...)

        # segments must be numbers
        my $maxSegment = $field[4];
        if ( !$maxSegment || $maxSegment !~ m|^\d+$| ) {
            $self->error("Segments is not number in row [$sheetName:$rowCounter]");
            next;
        }

        # codepage
        if ( !$field[5] || $field[5] eq "" ) {
            $self->error("Codepage not defined [$sheetName:$rowCounter]");
            next;
        }

        # language
        if ( !$field[6] || $field[6] !~ m/^[a-z]{3}$/i ) {
            $self->error("Incorrect language code [$sheetName:$rowCounter]");
            next;
        }

        # check for source
        if ( !$field[7] || $field[7] eq "" ) {
            $self->error("URL missing in row [SERVICE:$rowCounter]");
            $field[7] = "";
            next;
        }

        # workaround
        my $source = $field[7];
        $source =~ s/^web:/http:/i;

        # UTF8 handling
        my $name = $field[0];
        utf8::upgrade($name);
        utf8::upgrade($source);

        # each segment is 3h
        # 8 segments per day
        my $sid     = $raw->{extendedSID} ? ( ( $field[1] << 16 ) + $field[2] ) : $field[2];
        my $service = {
            sid         => $sid,
            name        => $name,
            tsid        => $field[1],
            onid        => $field[3],
            codepage    => $field[5],
            maxsegments => $maxSegment,
            grabber     => {
                days   => ceil( $maxSegment / 8 ),
                update => $field[8],
                url    => $source,
            },
            language => $field[6],
            parser   => $field[9] . ( $field[10] ? '?' . $field[10] : '' ),
        };
        CORE::push( @{ $raw->{serviceList} }, $service );

    } ## end foreach my $rowCounter ( 1 ...)
} ## end sub parseService

=head3 parseEIT(  )

Columns in EIT sheet:
TSID	IP                Port    PID    exclude SID   option
1       udp://224.0.0.1   5500    18     35,79,90      PCR,TDT

=cut

sub parseEIT {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my @field = Spreadsheet::Read::row( $sheet, $rowCounter );
        my %exclude;
        my %option;
        if ( scalar(@field) < 4 ) {
            $self->error("Not enough columns in row [$sheetName:$rowCounter]");
            next;
        }

        # skip column name row
        next if !$field[0] || $field[0] =~ m/tsid/i || $rowCounter == 1;

        # remove leading and trailing spaces, ', "
        foreach (@field) {
            next if !defined;
            s/^[\s'"]+//;
            s/[\s'"]+$//;
        }

        # tsid, port and pid must be numbers
        if (   $field[0] !~ m|^\d+$|
            || $field[2] !~ m|^\d+$|
            || $field[3] !~ m|^\d+$| ) {
            $self->error("TSID, port or PID are not numbers in row [$sheetName:$rowCounter]");
            next;
        } ## end if ( $field[0] !~ m|^\d+$|...)

        # check ip format
        if ( !is_ipv4( $field[1] ) ) {
            $self->error("IP has incorrect format in row [$sheetName:$rowCounter]");
            next;
        }

        # check exclude list
        if ( $field[4] and $field[4] ne "" ) {
            my @list   = split( / *, */, $field[4] );    # implicit remove spaces
            my $listOk = 1;
            foreach (@list) {
                if ( !m/^\d+$/ ) {
                    $self->error("Incorrect exclude list format in row [$sheetName:$rowCounter]");
                    $listOk = 0;
                    last;
                }
            } ## end foreach (@list)

            # map list to hash
            if ($listOk) {
                @exclude{@list} = (1) x @list;
            }
        } ## end if ( $field[4] and $field...)

        # map elements in option field to keys
        if ( $field[5] and $field[5] ne "" ) {
            my @list = split( / *, */, $field[5] );    # implicit remove spaces
            foreach (@list) {
                my ( $key, $value ) = split(/ *= */);
                my $uKey = uc($key);
                my @list = qw( NOMESH SEMIMESH PCR TDT TSID MAXBITRATE COPY PAT SDT PMT);
                if ( $uKey ~~ @list ) {
                    $value += 0 if $value && $value =~ /^\d+$/;
                    $option{$uKey} = defined $value ? $value : 1;
                } else {
                    $self->error("Unknown option: $key in row [$sheetName:$rowCounter]");
                }
            } ## end foreach (@list)
        } ## end if ( $field[5] and $field...)

        my $eit = {
            tsid    => $field[0],
            output  => $field[1] . ':' . $field[2],
            pid     => $field[3],
            exclude => \%exclude,
            option  => \%option,
            comment => ''
        };

        CORE::push( @{ $raw->{eit}{$sheetName} }, $eit );

    } ## end foreach my $rowCounter ( 1 ...)
} ## end sub parseEIT

=head3 parseConf(  )

Columns in CONF sheet:
optionname | value

=cut

sub parseConf {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    # use to generate uniq url for uploading
    my $salt;

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my @field = Spreadsheet::Read::row( $sheet, $rowCounter );

        # skip lines with empty first cell
        next if !defined $field[0];

        # skip column name row
        next if defined $field[0] && [0] =~ m/option/i || $rowCounter == 1;

        # remove leading and trailing spaces, ', "
        foreach (@field) {
            next if !defined;
            s/^[\s'"]+//;
            s/[\s'"]+$//;
        }

        if ( $field[0] =~ m /nomesh/i ) {
            $raw->{nomesh} = $field[1] ? 1 : 0;
        } elsif ( $field[0] =~ m /^xsid$/i ) {
            $raw->{extendedSID} = $field[1] ? 1 : 0;
        } elsif ( $field[0] =~ m /^semimesh$/i ) {
            $raw->{semimesh} = $field[1] ? 1 : 0;
        } elsif ( $field[0] =~ m /^description$/i ) {
            $raw->{description} = $field[1];
        } elsif ( $field[0] =~ m /^noautorule$/i ) {
            $raw->{noautorule} = $field[1] ? 1 : 0;
        } elsif ( $field[0] =~ m /^salt$/i ) {
            $salt = $field[1];
        }
    } ## end foreach my $rowCounter ( 1 ...)

    if ( !$salt ) {
        $salt = $raw->{description} // '';
    }
    $raw->{salt} = $salt . hostname;
} ## end sub parseConf

=head3 parseRule(  )

Prepare rules from sheet.
Columns in RULE sheet
ID    EIT   Actual   TSI   SID   ONID
0     1     2        3     4     5

The parseRule table will be used only when the NOAUTORULE is set.
In this case the RULE sheet is defining rules to build EPG output from input services.
The services are idenified by ID and reference to SID in the SERVICE sheet.
This is the only column used for mapping services to output streams.
SERVICE->SID = RULE->ID
EIT->TSID = RULE->EIT

=cut

sub parseRule {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my @field = Spreadsheet::Read::row( $sheet, $rowCounter );
        my %exclude;
        my %option;
        if ( scalar(@field) < 6 ) {
            $self->error("Not enough columns in row [$sheetName:$rowCounter]");
            next;
        }

        if ( $field[6] && $field[6] =~ m/IGNORE/ ) {
            $raw->{countIgnored} += 1;
            next;
        }

        # skip column starting with empty cell
        next if !$field[0] || $field[0] =~ m/id/i || $rowCounter == 1;

        # all cells must be number
        my $failed = 0;
        foreach ( @field[ 0 .. 5 ] ) {
            if ( !defined $_ ) {
                $self->error("Cell not defined in row [$sheetName:$rowCounter]");
                $failed += 1;
                next;
            }
            if ( !m/^\d+$/ ) {
                $self->error("Cell in row [$sheetName:$rowCounter] not number");
                $failed += 1;
                last;
            }
        } ## end foreach ( @field[ 0 .. 5 ] )

        return if $failed;

        my $rule = {
            actual              => $field[2] ? 1 : 0,
            channel_id          => $field[0] + 0,
            eit_id              => $field[1] + 0,
            comment             => $field[6],
            original_network_id => $field[5] + 0,
            service_id          => $field[4] + 0,
            transport_stream_id => $field[3] + 0,
        };
        CORE::push( @{ $raw->{rule} }, $rule );
    } ## end foreach my $rowCounter ( 1 ...)
} ## end sub parseRule

=head3 build( $target )

Validate raw data and build the final scheme for importing.
If no target defined use system hostname.
Return $scheme

=cut

sub build {
    my ( $self, $target ) = @_;

    $target = $target // hostname;
    my $raw    = $self->{raw};
    my $scheme = {
        eit     => [],
        rule    => [],
        channel => []
    };
    my $_target = '';

    # check if EIT for target exists
    if ( exists $raw->{eit}{ "EIT|" . $target } ) {
        $scheme->{target} = $target;
        $_target = "EIT|" . $target;
    } elsif ( exists $raw->{eit}{EIT} ) {
        $scheme->{target} = undef;
        $_target = "EIT";
    }

    # make hash of all TSID defined in output
    my $tsHash = {};
    my $output = {};    # key is ip:port:pid

    foreach my $eit ( @{ $raw->{eit}{$_target} } ) {
        my $tsid = $eit->{tsid};
        if ( exists $tsHash->{$tsid} ) {
            $self->error("Duplicate TS output [$tsid]");
        } else {
            $tsHash->{$tsid} = $eit;
            my $o = $eit->{output} . ':' . $eit->{pid};
            if ( exists $output->{$o} ) {
                $self->error("Cannot use same output for two TS [$tsid,$output->{$o}]");
            } else {
                $output->{$o} = $tsid;
            }
        } ## end else [ if ( exists $tsHash->{...})]
    } ## end foreach my $eit ( @{ $raw->...})

    # make hash of services by channel_id
    my $serviceHash = {};

    foreach my $service ( @{ $raw->{serviceList} } ) {
        my $tsid = $service->{tsid};

        # check for duplicate
        if ( exists $serviceHash->{ $service->{sid} } ) {
            $self->error("Duplicate SID [$service->{sid}]");
            next;
        } else {
            $serviceHash->{ $service->{sid} } = 1;

            # add salted url to service info
            my $url = substr( md5_base64( encode_utf8( $raw->{salt} . $service->{sid} ) ), 0, 8 );
            $url =~ s/[\/\+]/X/g;
            $service->{post} = $url;
        } ## end else [ if ( exists $serviceHash...)]
    } ## end foreach my $service ( @{ $raw...})

    if ( !$raw->{noautorule} ) {

        # generate rules based on service and EIT sheet

        # make hash of all TSID used in service sheet
        my $tsByService = {};

        foreach my $service ( @{ $raw->{serviceList} } ) {
            my $tsid = $service->{tsid};
            if ( !exists $tsByService->{$tsid} ) {
                $tsByService->{$tsid} = {};

                # check if the output for this TSID is defined
                if ( !exists $tsHash->{$tsid} ) {
                    $self->error("Output for TSID [$tsid] not defined");
                }
            } ## end if ( !exists $tsByService...)
            $tsByService->{$tsid}{ $service->{sid} } = $service;
        } ## end foreach my $service ( @{ $raw...})

        # build list of actual, other
        foreach my $tsid ( keys %$tsHash ) {
            $tsHash->{$tsid}{tables}{actual} = [];
            $tsHash->{$tsid}{tables}{other}  = [];

            foreach my $service ( @{ $raw->{serviceList} } ) {

                # check exclude and skip
                # we check only by sid not by onid|tsid|sid
                my $sid = $service->{sid};
                next if exists $tsHash->{$tsid}{exclude}{$sid};

                if ( $service->{tsid} == $tsid ) {
                    CORE::push( @{ $tsHash->{$tsid}{tables}{actual} }, $service );
                } else {
                    next if ( $tsHash->{$tsid}{option}{NOMESH} || $raw->{nomesh} );
                    CORE::push( @{ $tsHash->{$tsid}{tables}{other} }, $service );
                }
            } ## end foreach my $service ( @{ $raw...})
        } ## end foreach my $tsid ( keys %$tsHash)

        # generate eit & rules
        my $eitCounter = 0;
        foreach my $tsid ( sort { $a <=> $b } keys %$tsHash ) {

            $eitCounter += 1;
            my $eit = {
                eit_id => $eitCounter,
                pid    => $tsHash->{$tsid}{pid} + 0,    # must be numeric
                output => $tsHash->{$tsid}{output},
                option => $tsHash->{$tsid}{option}
            };

            # update options from CONF sheet
            $eit->{option}{SEMIMESH} = $raw->{semimesh} if $raw->{semimesh} and !defined $eit->{option}{SEMIMESH};

            CORE::push( @{ $scheme->{eit} }, $eit );

            # list both (actual, other)
            foreach my $table ( keys %{ $tsHash->{$tsid}{tables} } ) {

                # just build a rule
                foreach my $service ( @{ $tsHash->{$tsid}{tables}{$table} } ) {

                    my $rule = {
                        actual              => ( $table eq 'actual' ? 1 : 0 ),
                        channel_id          => $service->{sid},
                        eit_id              => $eitCounter,
                        comment             => '',
                        original_network_id => $service->{onid},
                        service_id          => $service->{sid},
                        transport_stream_id =>
                            ( exists $tsHash->{$tsid}{option}{TSID} ? $tsHash->{$tsid}{option}{TSID} : $service->{tsid} ),
                    };
                    CORE::push( @{ $scheme->{rule} }, $rule );
                } ## end foreach my $service ( @{ $tsHash...})
            } ## end foreach my $table ( keys %{...})
        } ## end foreach my $tsid ( sort { $a...})
    } else {

        # we use an alternative way to generate rules

        # check if service by ID exists
        # check if output EIT_ID exists
        # verify for uniq rules
        my $ruleById = {};
        my $eitInUse = {};

        foreach my $in ( $raw->{rule}->@* ) {
            my $id     = $in->{channel_id};
            my $eit_id = $in->{eit_id};

            if ( !exists $serviceHash->{$id} ) {
                $self->error("Service for ID (SID) [$id] not defined");
            }

            if ( !exists $tsHash->{$eit_id} ) {
                $self->error("Output for TSID [$eit_id] not defined");
            } else {
                $eitInUse->{$eit_id} = 1;
            }

            if ( !exists $ruleById->{$id} ) {
                $ruleById->{$id} = {};
            }
            if ( exists $ruleById->{$id}{$eit_id} ) {
                $self->error("Service is mapped to same EIT more than once [$id->$eit_id]");
            }
            $ruleById->{$id}{$eit_id} = 1;

            my $rule = {%$in};

            CORE::push( $scheme->{rule}->@*, $rule );
        } ## end foreach my $in ( $raw->{rule...})

        foreach my $eit_id ( sort { $a <=> $b } keys %$eitInUse ) {
            my $eit = {
                eit_id => $eit_id,
                pid    => $tsHash->{$eit_id}{pid} + 0,    # must be numeric
                output => $tsHash->{$eit_id}{output},
                option => $tsHash->{$eit_id}{option}
            };

            # update options from CONF sheet
            $eit->{option}{SEMIMESH} = $raw->{semimesh} if $raw->{semimesh} and !defined $eit->{option}{SEMIMESH};

            CORE::push( $scheme->{eit}->@*, $eit );
        } ## end foreach my $eit_id ( sort {...})
    } ## end else [ if ( !$raw->{noautorule...})]

    my @sortedRule =
        sort {
               $a->{transport_stream_id} <=> $b->{transport_stream_id}
            || $b->{actual}              <=> $a->{actual}
            || $a->{channel_id}          <=> $b->{channel_id}
        } @{ $scheme->{rule} };

    $scheme->{rule} = \@sortedRule;

    # copy sorted list of channels to scheme
    my @sortedChannel =
        map { delete $_->{tsid}; delete $_->{onid}; $_->{channel_id} = $_->{sid}; delete $_->{sid}; $_ }
        sort { $a->{sid} <=> $b->{sid} } @{ $raw->{serviceList} };

    # map channels to scheme
    $scheme->{channel} = \@sortedChannel;

    # generate PAT, SDT, PMT
    $self->tableBuilder($scheme);

    $scheme->{isValid} = scalar @{ $self->error } == 0;

    # copy raw part
    $scheme->{source} = $raw->{source};

    $self->{scheme} = $scheme;
    return $scheme;
} ## end sub build

=head3 tableBuilder( $scheme)

Build SDT, PAT and PMT tables.
Add them to $scheme->{table}.

=cut

sub tableBuilder {
    my ( $self, $scheme ) = @_;

    # first convert rules and service list to hash
    my %channel = map { $_->{channel_id} => $_ } $scheme->{channel}->@*;
    my %channelByEit;
    foreach my $rule ( $scheme->{rule}->@* ) {
        next if !$rule->{actual};
        if ( !$channelByEit{ $rule->{eit_id} } ) {
            $channelByEit{ $rule->{eit_id} } = {
                original_network_id => $rule->{original_network_id},
                transport_stream_id => $rule->{transport_stream_id},
                service             => {}
            };
        } ## end if ( !$channelByEit{ $rule...})
        $channelByEit{ $rule->{eit_id} }{service}{ $rule->{service_id} } = $rule->{channel_id};
    } ## end foreach my $rule ( $scheme->...)

    $scheme->{table} = {};
    foreach my $eit ( $scheme->{eit}->@* ) {

        my %pmtByService = ();

        # build PAT always and prepare PMT
        my $table = {
            '..' => {
                dst      => $eit->{output},
                interval => 500,
                title    => "Auto PAT",
            },
            table               => 'PAT',
            pid                 => 0,
            transport_stream_id => $channelByEit{ $eit->{eit_id} }{transport_stream_id},
            programs            => []
        };

        my $pmtPid = 100;
        $pmtPid = $eit->{option}{PMT} if $eit->{option}{PMT} && $eit->{option}{PMT} > 1;

        foreach my $service ( sort keys $channelByEit{ $eit->{eit_id} }{service}->%* ) {
            CORE::push(
                $table->{programs}->@*,
                {
                    program_number => $service,
                    pid            => $pmtPid
                }
            );
            $pmtByService{$service} = $pmtPid++;
        } ## end foreach my $service ( sort ...)

        # but generate only if requested
        if ( $eit->{option}{PAT} ) {
            my $filename = sprintf( "eit_%03i_pat", $eit->{eit_id} );
            $scheme->{table}{$filename} = $table;
        }

        # build SDT
        if ( $eit->{option}{SDT} ) {
            my $table = {
                '..' => {
                    dst      => $eit->{output},
                    interval => 4000,
                    title    => "Auto SDT",
                },
                table               => 'SDT',
                pid                 => 17,
                transport_stream_id => $channelByEit{ $eit->{eit_id} }{transport_stream_id},
                original_network_id => $channelByEit{ $eit->{eit_id} }{original_network_id},
                services            => []
            };
            foreach my $service ( sort keys $channelByEit{ $eit->{eit_id} }{service}->%* ) {

                my $detail = $channel{ $channelByEit{ $eit->{eit_id} }{service}{$service} };
                my $item   = {
                    service_id                 => $service,
                    eit_schedule_flag          => 1,
                    eit_present_following_flag => 1,
                    running_status             => 4,
                    free_ca_mode               => 0,
                    descriptors                => [ {
                            service_descriptor => {
                                service_type          => 25,
                                service_provider_name => 'cherryhill.eu',
                                service_name          => $detail->{name}
                            }
                        }
                    ]
                };

                CORE::push( $table->{services}->@*, $item );
            } ## end foreach my $service ( sort ...)
            my $filename = sprintf( "eit_%03i_sdt", $eit->{eit_id} );
            $scheme->{table}{$filename} = $table;
        } ## end if ( $eit->{option}{SDT...})


        # build the PMT part
        if ( $eit->{option}{PMT} ) {
            my $count = 0;
            foreach my $service ( keys %pmtByService ) {
                my $table = {
                    '..' => {
                        dst      => $eit->{output},
                        interval => 500,
                        title    => "Auto PMT",
                    },
                    table                    => 'PMT',
                    pid                      => $pmtByService{$service},
                    pcr_pid                  => 0x1ffe,
                    program_number           => $service,
                    program_info_descriptors => [],
                    elementary_streams       => []
                };
                my $filename = sprintf( "eit_%03i_pmt%02i", $eit->{eit_id}, $count++ );
                $scheme->{table}{$filename} = $table;
            } ## end foreach my $service ( keys ...)
        } ## end if ( $eit->{option}{PMT...})
    } ## end foreach my $eit ( $scheme->...)
} ## end sub tableBuilder

=head3 error( @args )

Add @arg (sprintf style) to errorList.
Return errorList when called without argument.

=cut

sub error {
    my ( $self, @arg ) = @_;

    if ( scalar @arg ) {
        CORE::push( @{ $self->{errorList} }, sprintf( shift @arg, @arg ) );
    } else {
        return $self->{errorList};
    }
} ## end sub error

=head3 restore ( $target )

Restore $target from archive.
Return $scheme on success.

=cut

sub restore {
    my ( $self, $target ) = @_;

    my $path = dir( $self->cherry->config->{core}{scheme} );
    my $file = file( $path, $target . $archiveExtension );

    my $scheme = $self->Import($file);

    return $scheme;
} ## end sub restore

=head3 backup ()

Backup current scheme to archive in gzipped YAML string format.
Return $target on success.

=cut

sub backup {
    my ($self) = @_;

    my $target = gmtime->strftime("%Y%m%d%H%M%S");
    my $file   = file( $self->cherry->config->{core}{scheme}, $target . $archiveExtension );

    if ( $self->export( $file, 1 ) ) {
        $logger->info("backup scheme [$target]");
        return $target;
    } else {
        $logger->error("backup scheme [$target]");
        return;
    }
} ## end sub backup

=head3 delete ( $target )

Delete $target from archive.

=cut

sub delete {
    my ( $self, $target ) = @_;

    my $path = dir( $self->cherry->config->{core}{scheme} );
    my $file = file( $path, $target . $archiveExtension );

    if ( -e $file ) {
        return unlink($file);
    }
    return 0;
} ## end sub delete

=head3 list ( )

List all files in archive with detailed data.
Return hash.

=cut

sub list {
    my ($self) = @_;

    my $path = dir( $self->cherry->config->{core}{scheme} );

    my @list = ();

    if ( -d $path && -r _ && opendir( my $dir, $path ) ) {
        my @all = grep {/$archiveExtension$/} readdir($dir);
        closedir($dir);

        @all = sort { $b cmp $a } map { s/$archiveExtension$//; $_ } @all;

        foreach my $target (@all) {
            my $scheme = $self->restore($target);
            next unless $scheme;

            my $item = {
                timestamp   => gmtime->strptime( $target, "%Y%m%d%H%M%S" )->epoch(),
                eit         => scalar @{ $scheme->{eit} },
                channel     => scalar @{ $scheme->{channel} },
                rule        => scalar @{ $scheme->{rule} },
                source      => $scheme->{source}{filename}    // '-',
                description => $scheme->{source}{description} // '-',
                target      => $target,
            };
            CORE::push( @list, $item );
        } ## end foreach my $target (@all)
        return \@list;
    } ## end if ( -d $path && -r _ ...)
    return;
} ## end sub list

=head1 AUTHOR

This software is copyright (c) 2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
