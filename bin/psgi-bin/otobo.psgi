#!/usr/bin/env perl
# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2021 Rother OSS GmbH, https://otobo.de/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

=head1 NAME

otobo.psgi - OTOBO PSGI application

=head1 SYNOPSIS

    # using the default webserver
    plackup bin/psgi-bin/otobo.psgi

    # using the webserver Gazelle
    plackup --server Gazelle bin/psgi-bin/otobo.psgi

    # new process for every request , useful for development
    plackup --server Shotgun bin/psgi-bin/otobo.psgi

    # with profiling (untested)
    PERL5OPT=-d:NYTProf NYTPROF='trace=1:start=no' plackup bin/psgi-bin/otobo.psgi

=head1 DESCRIPTION

A PSGI application.

=head1 DEPENDENCIES

There are some requirements for running this application. Do something like the commands used
in F<otobo.web.dockerfile>.

    cp cpanfile.docker cpanfile
    cpanm --local-lib local Carton
    PERL_CPANM_OPT="--local-lib /opt/otobo_install/local" carton install

=head1 Profiling

To profile single requests, install Devel::NYTProf and start this script as:

    PERL5OPT=-d:NYTProf NYTPROF='trace=1:start=no' plackup bin/psgi-bin/otobo.psgi

For actual profiling append C<&NYTProf=mymarker> to a request.
This creates a file called nytprof-mymarker.out, which you can process with

    nytprofhtml -f nytprof-mymarker.out

Then point your browser at nytprof/index.html.

=cut

use strict;
use warnings;
use v5.24;
use utf8;

# expect that otobo.psgi is two level below the OTOBO root dir
use FindBin qw($Bin);
use lib "$Bin/../..";
use lib "$Bin/../../Kernel/cpan-lib";
use lib "$Bin/../../Custom";

## nofilter(TidyAll::Plugin::OTOBO::Perl::Dumper)
## nofilter(TidyAll::Plugin::OTOBO::Perl::Require)
## nofilter(TidyAll::Plugin::OTOBO::Perl::SyntaxCheck)
## nofilter(TidyAll::Plugin::OTOBO::Perl::Time)

# core modules
use Data::Dumper;
use Encode qw(:all);
use Cwd qw(abs_path);

# CPAN modules
use DateTime 1.08;
use Template  ();
use CGI::Carp ();
use Module::Refresh;
use Plack::Builder;
use Plack::Request;
use Plack::Response;
use Plack::App::File;

#use Data::Peek; # for development

# OTOBO modules
use Kernel::System::ObjectManager;
use Kernel::System::Web::App;
use if $ENV{OTOBO_SYNC_WITH_S3}, 'Kernel::System::Storage::S3';

# Preload Net::DNS if it is installed. It is important to preload Net::DNS because otherwise loading
#   could take more than 30 seconds.
eval {
    require Net::DNS;
};

# The OTOBO home is determined from the location of otobo.psgi.
my $Home = abs_path("$Bin/../..");

################################################################################
# Middlewares
################################################################################

# conditionally enable profiling, UNTESTED
my $NYTProfMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # check whether this request runs under Devel::NYTProf
        my $ProfilingIsOn = 0;
        if ( $ENV{NYTPROF} && $Env->{QUERY_STRING} =~ m/NYTProf=([\w-]+)/ ) {
            $ProfilingIsOn = 1;
            DB::enable_profile("nytprof-$1.out");
        }

        # do the work
        my $Res = $App->($Env);

        # clean up profiling, write the output file
        DB::finish_profile() if $ProfilingIsOn;

        return $Res;
    };
};

# Set a single entry in %ENV.
# $ENV{GATEWAY_INTERFACE} is used for determining whether a command runs in a web context.
# This setting is used internally by Kernel::System::Log, Kernel::Config::Defaults and in the support data collector.
# In the CPAN module DBD::mysql, $ENV{GATEWAY_INTERFACE} would enable mysql_auto_reconnect.
# In order to counter that, mysql_auto_reconnect is explicitly disabled in Kernel::System::DB::mysql.
my $SetSystemEnvMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # only the side effects are important
        local $ENV{GATEWAY_INTERFACE} = 'CGI/1.1';

        # enable for debugging UrlMap
        #local $ENV{PLACK_URLMAP_DEBUG} = 1;

        return $App->($Env);
    };
};

# Set a single entry in the PSGI environment.
my $SetPSGIEnvMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # this setting is only used by a test page
        $Env->{SERVER_SOFTWARE} //= 'otobo.psgi';

        return $App->($Env);
    };
};

# Determine, and possibly munge, the script name.
# This needs to be done early, as access checking middlewares need that info.

# TODO: is this still relevant ?
# $Env->{SCRIPT_NAME} contains the matching mountpoint. Can be e.g. '/otobo' or '/otobo/index.pl'
# $Env->{PATH_INFO} contains the path after the $Env->{SCRIPT_NAME}. Can be e.g. '/index.pl' or ''
# The extracted ScriptFileName should be something like:
#     customer.pl, index.pl, installer.pl, migration.pl, nph-genericinterface.pl, or public.pl
# Note the only the last part of the mount is considered. This means that e.g. duplicated '/'
# are gracefully ignored.

# Force a new manifestation of $Kernel::OM.
# This middleware must be enabled before there is any access to the classes that are
# managed by the OTOBO object manager.
# Completion of the middleware destroys the localised $Kernel::OM, thus
# triggering event handlers.
my $ManageObjectsMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # make sure that the managed objects will be recreated for the current request
        local $Kernel::OM = Kernel::System::ObjectManager->new();

        return $App->($Env);
    };
};

# Fix for environment settings in the FCGI-Proxy case.
# E.g. when apaches2-httpd-fcgi.include.conf is used.
my $FixFCGIProxyMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # In the apaches2-httpd-fcgi.include.conf case all incoming request should be handled.
        # This means that otobo.psgi expects that SCRIPT_NAME is either '' or '/' and that
        # PATH_INFO is something like '/otobo/index.pl'.
        # But we get PATH_INFO = '' and SCRIPT_NAME = '/otobo/index.pl'.
        if ( $Env->{PATH_INFO} eq '' && ( $Env->{SCRIPT_NAME} ne '' && $Env->{SCRIPT_NAME} ne '/' ) ) {
            ( $Env->{PATH_INFO}, $Env->{SCRIPT_NAME} ) = ( $Env->{SCRIPT_NAME}, '/' );
        }

        return $App->($Env);
    };
};

# '/' is translated to '/index.html', just like Apache DirectoryIndex
my $ExactlyRootMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        if ( $Env->{PATH_INFO} eq '' || $Env->{PATH_INFO} eq '/' ) {
            $Env->{PATH_INFO} = '/index.html';
        }

        return $App->($Env);
    };
};

# With S3 support, loader files are initially stored in S3.
# Sync them to the local file system so that Plack::App::File can deliver them.
# Checking the name is sufficient as the loader files contain a checksum.
my $SyncFromS3Middleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # We need a path like 'skins/Agent/default/css-cache/CommonCSS_1ecc5b62f0219ea138682633a165f251.css'
        # Double slashes are not ignored in S3.
        my $PathBelowHtdocs = $Env->{PATH_INFO};
        $PathBelowHtdocs =~ s!/$!!;
        $PathBelowHtdocs =~ s!^/!!;
        my $Location = "$Home/var/httpd/htdocs/$PathBelowHtdocs";

        if ( !-e $Location ) {
            my $StorageS3Object = Kernel::System::Storage::S3->new();
            my $FilePath        = join '/', 'OTOBO', 'var/httpd/htdocs', $PathBelowHtdocs;
            $StorageS3Object->SaveObjectToFile(
                Key      => $FilePath,
                Location => $Location,
            );
        }

        return $App->($Env);
    };
};

# This is inspired by Plack::Middleware::Refresh. But we roll our own middleware,
# as OTOOB has special requirements.
# The modules in Kernel/Config/Files must be exempted from the reloading
# as it is OK when they are removed. These not removed modules are reloaded
# for every request in Kernel::Config::Defaults::new().
my $ModuleRefreshMiddleware = sub {
    my $App = shift;

    return sub {
        my $Env = shift;

        # make sure that there is a refresh in the first iteration
        state $LastRefreshTime = 0;

        # don't do work for every request, just every $RefreshCooldown secondes
        my $Now                     = time;
        my $SecondsSinceLastRefresh = $Now - $LastRefreshTime;
        my $RefreshCooldown         = 10;

        # Maybe useful for debugging, these vars can be printed out in frontend modules
        # See https://github.com/RotherOSS/otobo/issues/1422
        #$Kernel::Now = $Now;
        #$Kernel::SecondsSinceLastRefresh = $SecondsSinceLastRefresh;
        #$Kernel::LastRefreshTime         = $LastRefreshTime;

        if ( $SecondsSinceLastRefresh > $RefreshCooldown ) {

            $LastRefreshTime = $Now;

            # refresh modules, igoring the files in Kernel/Config/Files
            MODULE:
            for my $Module ( sort keys %INC ) {
                next MODULE if $Module =~ m[^Kernel/Config/Files/];

                Module::Refresh->refresh_module_if_modified($Module);
            }

            # for debugging
            #$Kernel::RefreshDone = 1;
        }

        return $App->($Env);
    };
};

################################################################################
# Apps
################################################################################

# The most basic App, no permission check
my $HelloApp = sub {
    my $Env = shift;

    # Initially $Message is a string with active UTF8-flag.
    # But turn it into a byte array, at that is wanted by Plack.
    # The actual bytes are not changed.
    my $Message = "Hallo 🌍!";
    utf8::encode($Message);

    return [
        '200',
        [ 'Content-Type' => 'text/plain;charset=utf-8' ],
        [$Message],
    ];
};

# Sometimes useful for debugging, no permission check
my $DumpEnvApp = sub {
    my $Env = shift;

    # collect some useful info
    local $Data::Dumper::Sortkeys = 1;
    my $Message = Data::Dumper->Dump(
        [ "DumpEnvApp:", scalar localtime, $Env, \%ENV, \@INC, \%INC, '🦦' ],
        [qw(Title Time Env ENV INC_array INC_hash otter)],
    );

    # add some unicode
    $Message .= "unicode: 🦦 ⛄ 🥨\n";

    # emit the content as UTF-8
    utf8::encode($Message);

    return [
        '200',
        [ 'Content-Type' => 'text/plain;charset=utf-8' ],
        [$Message],
    ];
};

# Handler andler for 'otobo', 'otobo/', 'otobo/not_existent', 'otobo/some/thing' and such.
# Would also work for /dummy if mounted accordingly.
# Redirect via a relative URL to otobo/index.pl.
# No permission check,
my $RedirectOtoboApp = sub {
    my $Env = shift;

    # construct a relative path to otobo/index.pl
    my $Req      = Plack::Request->new($Env);
    my $OrigPath = $Req->path();
    my $Levels   = $OrigPath =~ tr[/][];
    my $NewPath  = join '/', map( {'..'} ( 1 .. $Levels ) ), 'otobo/index.pl';

    # redirect
    my $Res = Plack::Response->new();
    $Res->redirect($NewPath);

    # send the PSGI response
    return $Res->finalize();
};

# Server the files in var/httpd/httpd.
# When S3 is supported there is a check whether missing files can be fetched from S3.
# Access is granted for all.
my $HtdocsApp = builder {

    # Cache css-cache for 30 days
    enable_if { $_[0]->{PATH_INFO} =~ m{skins/.*/.*/css-cache/.*\.(?:css|CSS)$} } 'Plack::Middleware::Header',
        set => [ 'Cache-Control' => 'max-age=2592000 must-revalidate' ];

    # Cache css thirdparty for 4 hours, including icon fonts
    enable_if { $_[0]->{PATH_INFO} =~ m{skins/.*/.*/css/thirdparty/.*\.(?:css|CSS|woff|svn)$} } 'Plack::Middleware::Header',
        set => [ 'Cache-Control' => 'max-age=14400 must-revalidate' ];

    # Cache js-cache for 30 days
    enable_if { $_[0]->{PATH_INFO} =~ m{js/js-cache/.*\.(?:js|JS)$} } 'Plack::Middleware::Header',
        set => [ 'Cache-Control' => 'max-age=2592000 must-revalidate' ];

    # Cache js thirdparty for 4 hours
    enable_if { $_[0]->{PATH_INFO} =~ m{js/thirdparty/.*\.(?:js|JS)$} } 'Plack::Middleware::Header',
        set => [ 'Cache-Control' => 'max-age=14400 must-revalidate' ];

    # loader files might have to be synced from S3
    enable_if {
        $ENV{OTOBO_SYNC_WITH_S3}
            &&
            (
                $_[0]->{PATH_INFO} =~ m{skins/.*/.*/css-cache/.*\.(?:css|CSS)$}
                ||
                $_[0]->{PATH_INFO} =~ m{js/js-cache/.*\.(?:js|JS)$}
            )
    }
    $SyncFromS3Middleware;

    Plack::App::File->new( root => "$Home/var/httpd/htdocs" )->to_app();
};

# Port of customer.pl, index.pl, installer.pl, migration.pl, nph-genericinterface.pl, and public.pl to Plack.
my $OTOBOApp = builder {

    # compress the output
    # do not enable 'Plack::Middleware::Deflater', as there were errors with 'Wide characters in print'
    #enable 'Plack::Middleware::Deflater',
    #    content_type => [ 'text/html', 'text/javascript', 'application/javascript', 'text/css', 'text/xml', 'application/json', 'text/json' ];

    # a simplistic detection whether we are behind a revers proxy
    enable_if { $_[0]->{HTTP_X_FORWARDED_HOST} } 'Plack::Middleware::ReverseProxy';

    # conditionally enable profiling
    enable $NYTProfMiddleware;

    # Check ever 10s for changed Perl modules.
    # Exclude the modules in Kernel/Config/Files as these modules
    # are already reloaded Kernel::Config::Defaults::new().
    enable_if { !$ENV{OTOBO_SYNC_WITH_S3} } $ModuleRefreshMiddleware;

    # add the Content-Length header, unless it already is set
    # this applies also to content from Kernel::System::Web::Exception
    enable 'Plack::Middleware::ContentLength';

    # we might catch an instance of Kernel::System::Web::Exception
    enable 'Plack::Middleware::HTTPExceptions';

    # set up %ENV
    enable $SetSystemEnvMiddleware;

    # set up $Env
    enable $SetPSGIEnvMiddleware;

    # force destruction and recreation of managed objects
    enable $ManageObjectsMiddleware;

    # The actual functionality of OTOBO is implemented as a set of Plack apps.
    # Dispatching is done with an URL map.
    # Kernel::System::Web::App loads the interface modules and calls the Response() method.
    # Add "Debug => 1" in order to enable debugging.

    mount '/customer.pl' => Kernel::System::Web::App->new(
        Interface => 'Kernel::System::Web::InterfaceCustomer',
    )->to_app;

    mount '/index.pl' => Kernel::System::Web::App->new(
        Interface => 'Kernel::System::Web::InterfaceAgent',
    )->to_app;

    mount '/installer.pl' => builder {

        # check the SecureMode
        # Alternatively we could use Plack::Middleware::Access, but that modules is not available as a Debian package
        enable 'OTOBO::SecureModeAccessFilter',
            rules => [
                deny => 'securemode_is_on',
            ];

        Kernel::System::Web::App->new(
            Interface => 'Kernel::System::Web::InterfaceInstaller',
        )->to_app;
    };

    mount '/migration.pl' => builder {

        # check the SecureMode
        # Alternatively we could use Plack::Middleware::Access, but that modules is not available as a Debian package
        enable 'OTOBO::SecureModeAccessFilter',
            rules => [
                deny => 'securemode_is_on',
            ];

        Kernel::System::Web::App->new(
            Interface => 'Kernel::System::Web::InterfaceMigrateFromOTRS',
        )->to_app;
    };

    mount "/nph-genericinterface.pl" => Kernel::System::Web::App->new(
        Interface => 'Kernel::GenericInterface::Provider',
    )->to_app;

    mount "/public.pl" => Kernel::System::Web::App->new(
        Interface => 'Kernel::System::Web::InterfacePublic',
    )->to_app;

    # agent interface is the default
    mount '/' => $RedirectOtoboApp;    # redirect to /otobo/index.pl when in doubt
};

################################################################################
# finally, the complete PSGI application itself
################################################################################

builder {

    # for debugging
    #enable 'Plack::Middleware::TrafficLog';

    # '/' is translated to '/index.html', just like Apache DirectoryIndex
    enable $ExactlyRootMiddleware;

    # fixing PATH_INFO
    enable_if { ( $_[0]->{FCGI_ROLE} // '' ) eq 'RESPONDER' } $FixFCGIProxyMiddleware;

    # Server the files in var/httpd/htdocs.
    # Loader files, js and css, may be synced from S3 storage.
    mount '/otobo-web' => $HtdocsApp;

    # uncomment for trouble shooting
    #mount '/hello'          => $HelloApp;
    #mount '/dump_env'       => $DumpEnvApp;
    #mount '/otobo/hello'    => $HelloApp;
    #mount '/otobo/dump_env' => $DumpEnvApp;

    # Provide routes that are the equivalents of the scripts in bin/cgi-bin.
    # The pathes are such that $Env->{SCRIPT_NAME} and $Env->{PATH_INFO} are set up just like they are set up under mod_perl,
    mount '/otobo' => $OTOBOApp;

    # some static pages, '/' is already translate to '/index.html'
    mount "/robots.txt" => Plack::App::File->new( file => "$Home/var/httpd/htdocs/robots.txt" )->to_app;
    mount "/index.html" => Plack::App::File->new( file => "$Home/var/httpd/htdocs/index.html" )->to_app;
};

# enable for debugging: dump debugging info, including the PSGI environment, for any request
#$DumpEnvApp;
