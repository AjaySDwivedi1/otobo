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

my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

$Kernel::OM->ObjectParamAdd(
    'Kernel::System::UnitTest::Helper' => {
        RestoreDatabase  => 1,
        UseTmpArticleDir => 1,

    },
);
my $Helper = $Kernel::OM->Get('Kernel::System::UnitTest::Helper');

# force rich text editor
my $Success = $ConfigObject->Set(
    Key   => 'Frontend::RichText',
    Value => 1,
);
$Self->True(
    $Success,
    'Force RichText with true',
);

# use DoNotSendEmail email backend
$Success = $ConfigObject->Set(
    Key   => 'SendmailModule',
    Value => 'Kernel::System::Email::DoNotSendEmail',
);
$Self->True(
    $Success,
    'Set DoNotSendEmail backend with true',
);

# create a new user for current test
my $UserLogin = $Helper->TestUserCreate(
    Groups => ['users'],
);

my %UserData = $Kernel::OM->Get('Kernel::System::User')->GetUserData(
    User => $UserLogin,
);

my $UserID = $UserData{UserID};

# create new customer user for current test
my $CustomerUserLogin = $Helper->TestCustomerUserCreate();

my %CustomerUserData = $Kernel::OM->Get('Kernel::System::CustomerUser')->CustomerUserDataGet(
    User => $CustomerUserLogin,
);

my $TicketObject         = $Kernel::OM->Get('Kernel::System::Ticket');
my $ArticleObject        = $Kernel::OM->Get('Kernel::System::Ticket::Article');
my $ArticleBackendObject = $ArticleObject->BackendForChannel( ChannelName => 'Internal' );

# create ticket
my $TicketID = $TicketObject->TicketCreate(
    Title        => 'Ticket One Title',
    QueueID      => 1,
    Lock         => 'unlock',
    Priority     => '3 normal',
    State        => 'new',
    CustomerID   => 'example.com',
    CustomerUser => $CustomerUserData{UserEmail},
    OwnerID      => $UserID,
    UserID       => $UserID,
);

# sanity check
$Self->True(
    $TicketID,
    "TicketCreate() successful for Ticket ID $TicketID",
);

# get ticket number
my $TicketNumber = $TicketObject->TicketNumberLookup(
    TicketID => $TicketID,
    UserID   => $UserID,
);

$Self->True(
    $TicketNumber,
    "TicketNumberLookup() successful for Ticket# $TicketNumber"
);

my $ArticleID = $ArticleBackendObject->ArticleCreate(
    TicketID             => $TicketID,
    SenderType           => 'customer',
    IsVisibleForCustomer => 1,
    From                 => $CustomerUserData{UserEmail},
    To                   => $UserData{UserEmail},
    Subject              => 'some short description',
    Body                 => 'the message text',
    Charset              => 'utf8',
    MimeType             => 'text/plain',
    HistoryType          => 'OwnerUpdate',
    HistoryComment       => 'Some free text!',
    UserID               => 1,
);

# sanity check
$Self->True(
    $ArticleID,
    "ArticleCreate() successful for Article ID $ArticleID"
);

my $NotificationEventObject      = $Kernel::OM->Get('Kernel::System::NotificationEvent');
my $EventNotificationEventObject = $Kernel::OM->Get('Kernel::System::Ticket::Event::NotificationEvent');

# create add note notification
my $NotificationID = $NotificationEventObject->NotificationAdd(
    Name => 'Customer notification',
    Data => {
        Events     => ['ArticleCreate'],
        Recipients => ['Customer'],
        Transports => ['Email'],
    },
    Message => {
        en => {
            Subject => 'Test external note',

            # include non-breaking space (bug#10970)
            Body => 'Ticket:&nbsp;<OTOBO_TICKET_TicketID>&nbsp;<OTOBO_OWNER_UserFirstname>',

            ContentType => 'text/html',
        },
    },
    Comment => 'An optional comment',
    ValidID => 1,
    UserID  => 1,
);

# sanity check
$Self->IsNot(
    $NotificationID,
    undef,
    'NotificationAdd() should not be undef',
);

my $Result = $EventNotificationEventObject->Run(
    Event => 'ArticleCreate',
    Data  => {
        TicketID => $TicketID,
    },
    Config => {},
    UserID => 1,
);

$Self->True(
    $Result,
    'ArticleCreate event raised'
);

# Get ticket articles.
my @Articles = $ArticleObject->ArticleList(
    TicketID => $TicketID,
);

$Self->Is(
    scalar @Articles,
    2,
    'ArticleList() should return two elements',
);

# get last article
my %Article = $ArticleBackendObject->ArticleGet(
    TicketID  => $TicketID,
    ArticleID => $Articles[-1]->{ArticleID},    # last
);

$Self->Is(
    $Article{Subject},
    '[' . $ConfigObject->Get('Ticket::Hook') . $TicketNumber . '] Test external note',
    'ArticleGet() subject contains notification subject',
);

# delete notification event
my $NotificationDelete = $NotificationEventObject->NotificationDelete(
    ID     => $NotificationID,
    UserID => 1,
);

# sanity check
$Self->True(
    $NotificationDelete,
    "NotificationDelete() successful for Notification ID $NotificationID",
);

# cleanup

# delete the ticket
my $TicketDelete = $TicketObject->TicketDelete(
    TicketID => $TicketID,
    UserID   => $UserID,
);

# sanity check
$Self->True(
    $TicketDelete,
    "TicketDelete() successful for Ticket ID $TicketID",
);

# cleanup is done by RestoreDatabase.

$Self->DoneTesting();
