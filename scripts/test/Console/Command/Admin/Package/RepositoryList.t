# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2024 Rother OSS GmbH, https://otobo.de/
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

use strict;
use warnings;
use utf8;

# Set up the test driver $Self when we are running as a standalone script.
use Kernel::System::UnitTest::RegisterDriver;

our $Self;

my %List;
if ( $Kernel::OM->Get('Kernel::Config')->Get('Package::RepositoryList') ) {
    %List = %{ $Kernel::OM->Get('Kernel::Config')->Get('Package::RepositoryList') };
}
%List = ( %List, $Kernel::OM->Get('Kernel::System::Package')->PackageOnlineRepositories() );

my $CommandObject = $Kernel::OM->Get('Kernel::System::Console::Command::Admin::Package::RepositoryList');

# get helper object
$Kernel::OM->ObjectParamAdd(
    'Kernel::System::UnitTest::Helper' => {
        RestoreDatabase => 1,
    },
);
my $Helper = $Kernel::OM->Get('Kernel::System::UnitTest::Helper');

my $ExitCode = $CommandObject->Execute();

$Self->Is(
    $ExitCode,
    %List ? 0 : 1,
    "Admin::Package::RepositoryList exit code without arguments",
);

# cleanup cache is done by RestoreDatabase

$Self->DoneTesting();
