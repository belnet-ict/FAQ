#!/usr/bin/perl
# --
# otrs.FAQImport.pl - FAQ import script
# Copyright (C) 2001-2014 OTRS AG, http://otrs.com/
# --
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU AFFERO General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
# or see http://www.gnu.org/licenses/agpl.txt.
# --

use strict;
use warnings;

use File::Basename;
use FindBin qw($RealBin);
use lib dirname($RealBin);
use lib dirname($RealBin) . '/Kernel/cpan-lib';

use Getopt::Std;
use Kernel::Config;
use Kernel::System::DB;
use Kernel::System::Encode;
use Kernel::System::CSV;
use Kernel::System::Log;
use Kernel::System::Main;
use Kernel::System::Time;
use Kernel::System::Group;
use Kernel::System::FAQ;

use vars qw($RealBin);

# create common objects
my %CommonObject;
$CommonObject{UserID}       = 1;
$CommonObject{ConfigObject} = Kernel::Config->new();
$CommonObject{LogObject}    = Kernel::System::Log->new(
    LogPrefix => 'OTRS-FAQImport',
    %CommonObject,
);
$CommonObject{CSVObject}    = Kernel::System::CSV->new(%CommonObject);
$CommonObject{EncodeObject} = Kernel::System::Encode->new(%CommonObject);
$CommonObject{MainObject}   = Kernel::System::Main->new(%CommonObject);
$CommonObject{DBObject}     = Kernel::System::DB->new(%CommonObject);
$CommonObject{TimeObject}   = Kernel::System::Time->new(%CommonObject);
$CommonObject{GroupObject}  = Kernel::System::Group->new(%CommonObject);
$CommonObject{FAQObject}    = Kernel::System::FAQ->new(%CommonObject);

# get options
my %Opts;
getopt( 'hisq', \%Opts );

if ( exists $Opts{h} ) {
    print STDOUT "\n";
    print STDOUT "otrs.FAQImport.pl - a FAQ import tool\n";
    print STDOUT "Copyright (C) 2001-2014 OTRS AG, http://otrs.com/\n";
    print STDOUT "   usage: \n";
    print STDOUT "      otrs.FAQImport.pl -i <ImportFile> [-s <separator>] [-q <quote>]\n";
    print STDOUT "\n";
    print STDOUT "   examples:\n";
    print STDOUT "       otrs.FAQImport.pl -i faq.csv\n";
    print STDOUT "       otrs.FAQImport.pl -i faq.csv -s '|' -q '\"' \n";
    print STDOUT "\n";
    print STDOUT "   Format of the CSV file:\n";
    print STDOUT '       "title";"category";"language";"statetype";';
    print STDOUT '"field1";"field2";"field3";"field4";"field5";"field6";"keywords"' . "\n";
    print STDOUT "\n";
    exit 1;
}

# check action mode
if ( !$Opts{i} ) {
    print STDERR "ERROR: Need -i <ImportFile>\n";
    exit 1;
}

print STDOUT "Read File $Opts{i}.\n";

# read source file
my $CSVStringRef = $CommonObject{MainObject}->FileRead(
    Location => $Opts{i},
    Result   => 'SCALAR',
    Mode     => 'binmode',
);
die "Can't read file $Opts{i}.\nImport aborted.\n" if !$CSVStringRef;

print STDOUT "Import in process...\n";

# read csv data
my $DataRef = $CommonObject{CSVObject}->CSV2Array(
    String    => $$CSVStringRef,
    Separator => $Opts{s} || ';',
    Quote     => $Opts{q} || '"',
);
die "\nError occurred. Import impossible! See Syslog for details.\n" if !defined $DataRef;

# get all FAQ language ids
my %LanguageID = reverse $CommonObject{FAQObject}->LanguageList(
    UserID => 1,
);

# get all state type ids
my %StateTypeID = reverse %{ $CommonObject{FAQObject}->StateTypeList( UserID => 1 ) };

# get group id for faq group
my $FAQGroupID = $CommonObject{GroupObject}->GroupLookup(
    Group => 'faq',
);

my $LineCounter;
ROW:
for my $RowRef ( @{$DataRef} ) {

    $LineCounter++;

    my (
        $Title, $CategoryString, $Language, $StateType,
        $Field1, $Field2, $Field3, $Field4, $Field5, $Field6, $Keywords
    ) = @{$RowRef};

    # check language
    if ( !$LanguageID{$Language} ) {
        print STDOUT
            "Error: Could not import line $LineCounter. Language '$Language' does not exist.\n";
        next ROW;
    }

    # check state type
    if ( !$StateTypeID{$StateType} ) {
        print STDOUT
            "Error: Could not import line $LineCounter. State '$StateType' does not exist.\n";
        next ROW;
    }

    # get subcategories
    my @CategoryArray = split /::/, $CategoryString;

    # check each subcategory if it exists
    my $CategoryID;
    my $ParentID = 0;
    for my $Category (@CategoryArray) {

        # get the category id
        $CommonObject{DBObject}->Prepare(
            SQL => 'SELECT id FROM faq_category '
                . 'WHERE valid_id = 1 AND name = ? AND parent_id = ?',
            Bind => [ \$Category, \$ParentID ],
            Limit => 1,
        );
        my @Result;
        while ( my @Row = $CommonObject{DBObject}->FetchrowArray() ) {
            push( @Result, $Row[0] );
        }
        $CategoryID = $Result[0];

        # create category if it does not exist
        if ( !$CategoryID ) {
            $CategoryID = $CommonObject{FAQObject}->CategoryAdd(
                Name     => $Category,
                ParentID => $ParentID,
                ValidID  => 1,
                UserID   => 1,
            );

            # add new category to faq group
            $CommonObject{FAQObject}->SetCategoryGroup(
                CategoryID => $CategoryID,
                GroupIDs   => [$FAQGroupID],
            );
        }

        # set new parent id
        $ParentID = $CategoryID;
    }

    # check category
    if ( !$CategoryID ) {
        print STDOUT
            "Error: Could not import line $LineCounter. Category '$CategoryString' could not be created.\n";
        next ROW;
    }

    # add FAQ article
    my $FAQID = $CommonObject{FAQObject}->FAQAdd(
        Title      => $Title,
        CategoryID => $CategoryID,
        StateID    => $StateTypeID{$StateType},
        LanguageID => $LanguageID{$Language},
        Field1     => $Field1,
        Field2     => $Field2,
        Field3     => $Field3,
        Field4     => $Field4,
        Field5     => $Field5,
        Field6     => $Field6,
        Keywords   => $Keywords || '',
        Approved   => 1,
        UserID     => 1,
    );

    # check success
    if ( !$FAQID ) {
        print STDOUT "Error: Could not import line $LineCounter.\n";
        next ROW;
    }
}

print STDOUT "Import complete.\n";

exit 0;

=back

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
