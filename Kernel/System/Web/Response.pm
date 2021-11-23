# --
# OTOBO is a web-based ticketing system for service organisations.
# --
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

package Kernel::System::Web::Response;

use strict;
use warnings;
use v5.24;
use namespace::clean;
use utf8;

# core modules

# CPAN modules
use Plack::Response;

# OTOCO modules
use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
);

=head1 NAME

Kernel::System::Web::Response - a wrapper around Plack::Response

=head1 DESCRIPTION

A wrapper around L<Plack::Response>.
Used for collecting the HTTP headers that should be emitted.
Also, the status code set in this object overrides in F<otobo.psgi> the default status code 200..

=head1 PUBLIC INTERFACE

=head2 new()

create an web response object. Do not use it directly, instead use:

    use Kernel::System::ObjectManager;

    local $Kernel::OM = Kernel::System::ObjectManager->new();

    my $ResponseObject = $Kernel::OM->Get('Kernel::System::Web::Response');

=cut

sub new {
    my ( $Class, @Args ) = @_;

    # wrap an instance of Plack::Response
    return bless
        {
            Response => Plack::Response->new(@Args),
        },
        $Class;
}

=head2 Headers()

a wrapper around Plack::Response::headers().

=cut

sub Headers {
    my ( $Self, @Args ) = @_;

    return $Self->{Response}->headers(@Args);
}

=head2 Header()

a wrapper around Plack::Response::header().

=cut

sub Header {
    my ( $Self, @Args ) = @_;

    return $Self->{Response}->header(@Args);
}

=head2 Cookies()

a wrapper around Plack::Response::cookies().

=cut

sub Cookies {
    my ( $Self, @Args ) = @_;

    return $Self->{Response}->cookies(@Args);
}

=head2 Code()

a wrapper around Plack::Response::code().

=cut

sub Code {
    my ( $Self, @Args ) = @_;

    return $Self->{Response}->code(@Args);
}

=head2 Content()

a wrapper around Plack::Response::content().

=cut

sub Content {
    my ( $Self, @Args ) = @_;

    return $Self->{Response}->body(@Args);
}

=head2 Finalize()

a wrapper around Plack::Response::finalize().
Also set default status and the passed in content.

=cut

sub Finalize {
    my ( $Self, %Param ) = @_;

    my $Content = $Param{Content} // '';

    # Keep the HTTP status code when it already was set.
    # Otherwise assume that the request was successful and set the code to 200.
    $Self->Code(200) unless $Self->Code();

    # The content is UTF-8 encoded when the header Content-Type has been set up like:
    #   'Content-Type'    => 'text/html; charset=utf-8'
    # This is the regular case, see Kernel::Output::HTML::Layout::_AddHeadersToResponseOBject().
    if ( !ref $Content || ref $Content eq 'ARRAY' ) {
        my $Charset = $Self->Headers->content_type_charset // '';
        if ( $Charset eq 'UTF-8' ) {
            if ( ref $Content eq 'ARRAY' ) {
                for my $Item ( $Content->@* ) {
                    utf8::encode($Item);
                }
            }
            else {
                utf8::encode($Content);
            }
        }
    }
    $Self->Content($Content);    # a file handle is acceptable here

    # return the PSGI response, a funnny unblessed array reference with three elements
    return $Self->{Response}->finalize();
}

1;