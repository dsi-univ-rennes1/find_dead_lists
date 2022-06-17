#!/usr/bin/perl

# 31/01/2022 (OS) : détection des listes mortes en vue de leur fermeture

use lib split(/:/, '/usr/local/sympa/bin' || '');

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;

use Sympa;
use Conf;
use Sympa::Config_XML;
use Sympa::Constants;
use Sympa::DatabaseManager;
use Sympa::Family;
use Sympa::Language;
use Sympa::List;
use Sympa::Log;
use Sympa::Mailer;
use Sympa::Spindle::ProcessDigest;
use Sympa::Spindle::ProcessRequest;
use Sympa::Template;
use Sympa::Tools::Data;
use Sympa::Upgrade;

use Data::Dumper;
use Text::CSV;
use Template;
use File::Basename;
use List::MoreUtils qw(uniq);

use confCleanup;

my %options;
&GetOptions(\%options, 'help', 'check','prepare_cleanup','do_cleanup','csv=s','test');

my $one_year = 3600 * 24 * 365;
my $current_year = POSIX::strftime("%Y", localtime(time));
my $current_dir = dirname(__FILE__);

sub load_csv {
    my $csv_file = shift;
    my $sep_char = shift;
    
    my $rows;
    my $csv = Text::CSV->new ( { binary => 1, sep_char=> $sep_char } )  # should set binary attribute.
                 or die "Cannot use CSV: ".Text::CSV->error_diag ();
 
    open my $fh, "<:encoding(utf8)", $csv_file;
    $csv->column_names ($csv->getline ($fh)) or die;
    $rows = $csv->getline_hr_all( $fh ) or die;
    $csv->eof or $csv->error_diag();
    close $fh;
    
    return $rows;
}

if ($options{'help'}) {
    printf "$0 --check > inventory.csv\n";
    printf "$0 --prepare_cleanup --csv=inventory.csv\n";
    printf "$0 --do_cleanup --test --csv=actions.csv\n";
    printf "$0 --do_cleanup --csv=actions.csv\n";
    exit 0;
}
## Load Sympa.conf
unless (defined Conf::load()) {
    printf STDERR "Unable to load sympa configuration, file %s or one of the vhost robot.conf files contain errors. Exiting.\n", Conf::get_sympa_conf();
    exit 1;
}

if ($options{'check'}) {

    # Load all valid email addresses from LDAP
    my $ldap_search = "ldapsearch -o ldif-wrap=no -x -D ". $confCleanup::ldap_bind_dn . " -w " . $confCleanup::ldap_bind_password . " -H " . $confCleanup::ldap_server . " -b " . $confCleanup::ldap_base . " 'uid=*' mail mailAlternateAddress |grep -P '^(mail|mailAlternateAddress)' | perl -pe 's/^\\w+:\\s+//'|sort -u > $current_dir/all_ldap_mail.txt";
    `$ldap_search`;
    `cat $current_dir/all_ldap_mail.txt |perl -pe 's/^.*\@(.*)\$/\\1/'|sort -u > $current_dir/all_mail_domains.txt`;
    
    my %domains = ();
    open DOMAINS, '$current_dir/all_mail_domains.txt';
    while (<DOMAINS>) {
        chomp;
        $domains{lc($_)} = 1;
    }
    close DOMAINS;
    
    my %valid_mail = ();
    open ALLMAIL, '$current_dir/all_ldap_mail.txt';
    while (<ALLMAIL>) {
        chomp;
        $valid_mail{lc($_)} = 1;
    }
    close ALLMAIL;
    
    
    # Go through all lists
    my $all_lists     = Sympa::List::get_lists('*');
    my %stats = ();
    printf "list_address;creation_year;year_last_message;members_count;count_valid_admin;inactivity_rate\n";
    foreach my $list (@{$all_lists || []}) {
        
        my $list_stats = {};
    
        # Ignore lists belonging to a family
        next if ($list->{'admin'}{'family_name'});
    
        # Ignore listes included by another list
        next if ($list->is_included);
    
        my $inactivity_indice = 0;
        next unless $list->{'admin'}{'status'} eq 'open';
        
        # Ignore lists tagged as "garder"
        # via custom_var ur1_statut="garder"
        if ($list->{'admin'}{'custom_vars'}) {
            foreach my $custom (@{$list->{'admin'}{'custom_vars'}}) {
                if ($custom->{'name'} eq 'ur1_statut' && $custom->{'value'} eq "garder") {
                    next;
                }
            }            
        }
    
        my $latest_mail = $list->get_latest_distribution_date() || 0;
        $latest_mail *= 86400;
        
        # Check owners/editors
        my %admin = ();
        foreach my $role ('owner','editor') {
            foreach my $user ($list->get_admins($role)) {
                $admin{lc($user->{'email'})} = undef;
            }
        }
    
        my $count_valid_admin = 0;
        foreach my $email (keys %admin) {
            my @splitted = split /\@/, $email;
            # Local domain
            if (defined $domains{$splitted[1]}) {
                if (! defined $valid_mail{$email}) {
                    next;
                }
            }
            $count_valid_admin++;
    
        }
    
        if ($count_valid_admin == 0) {
            $inactivity_indice++;
        }
    
        # Never used of last message more than 1 year old
        if ($latest_mail == 0 || $latest_mail < (time - $one_year)) {
            $inactivity_indice++;
    
            # Aggraving factor : list created 5 years ago
            if ($list->{'admin'}{'creation'} && $list->{'admin'}{'creation'}{'date_epoch'} &&
                $list->{'admin'}{'creation'}{'date_epoch'} < (time - ($one_year * 5))) {
                $inactivity_indice++;
            }
        }
    
        # Members count
        my $total_members = $list->get_total();
        $inactivity_indice++ if ($total_members == 0);
    
        my $latest_mail_formated;
        if ($latest_mail == 0) {
            $latest_mail_formated = 'never';
        }else {
            $latest_mail_formated = POSIX::strftime("%Y", localtime($latest_mail));
        }
    
        my $creation_year = '';
        if ($list->{'admin'}{'creation'}{'date_epoch'}) {
            $creation_year = POSIX::strftime("%Y", localtime($list->{'admin'}{'creation'}{'date_epoch'}));
        }
        
        printf "%s;%s;%s;%d;%d;%d\n", Sympa::get_address($list), $creation_year, $latest_mail_formated, $total_members, $count_valid_admin, $inactivity_indice;
    }
    
}elsif ($options{'prepare_cleanup'}) {
    my $inventory = load_csv($options{'csv'}, ';');
    
    printf "action;reason;list_address\n";
    foreach my $list_diag (@{$inventory}) {
        #printf Data::Dumper::Dumper($list_diag);
        if ($list_diag->{'count_valid_admin'} == 0) {
            if ($list_diag->{'inactivity_rate'} >= 2) {
                printf "CLOSE;no_admin+indices;%s\n", $list_diag->{'list_address'};
            }else {
                printf "CHECK;no_admin;%s\n", $list_diag->{'list_address'};
            }
            
        }elsif ("$list_diag->{'year_last_message'}" eq 'never') {
            if ($list_diag->{'creation_year'} && $list_diag->{'creation_year'} >= $current_year-1) {
                printf "KEEP;no_mail+recent;%s\n", $list_diag->{'list_address'};
            }else {
                if ($list_diag->{'inactivity_rate'} >= 2) {
                    printf "NOTIFY;no_mail+indices;%s\n", $list_diag->{'list_address'};
                }else {
                    printf "CHECK;no_mail;%s\n", $list_diag->{'list_address'};
                }
            }
            
        }elsif ($list_diag->{'year_last_message'} <  $current_year-5) {
            if ($list_diag->{'inactivity_rate'} >= 2) {
                printf "NOTIFY;mail5years+indices;%s\n", $list_diag->{'list_address'};
            }else {
                printf "CHECK;mail5years;%s\n", $list_diag->{'list_address'};
            }
        
        }elsif ($list_diag->{'members_count'} == 0) {
            if ($list_diag->{'inactivity_rate'} >= 2) {
                printf "NOTIFY;no_member+indices;%s\n", $list_diag->{'list_address'};
            }else {
                printf "CHECK;no_member;%s\n", $list_diag->{'list_address'};
            }
        
        }else {
            printf "OK;;%s\n", $list_diag->{'list_address'};
        }
    }
    
}elsif ($options{'do_cleanup'}) {
    my $actions = load_csv($options{'csv'}, ',');
    
    my ($total_fermer, $total_notifier);
    foreach my $list_action (@{$actions}) {
        $list_action->{'list_address'} =~ s/\s*$//;
        next if ($list_action->{'action'} =~ /^(OK|KEEP|CHECK)$/);
        printf "%s\t%s\n", $list_action->{'action'}, $list_action->{'list_address'};
        
        my ($listname, $listrobot) = split /\@/, $list_action->{'list_address'};
        my $list = Sympa::List->new($listname, $listrobot) or die "Unknown list $listname\@$listrobot";
        if ($list_action->{'action'} eq 'CLOSE') {
            $total_fermer++;
            unless ($options{'test'}) {
    
                if ($list_action->{'action'} eq 'CLOSE') {
                    my $spindle = Sympa::Spindle::ProcessRequest->new(
                        context          => $listrobot,
                        action           => 'close_list',
                        current_list     => $list,
                        sender           => Sympa::get_address($listrobot, 'listmaster'),
                        scenario_context => {skip => 1},
                    );
                    unless ($spindle and $spindle->spin) {
                        printf STDERR "Could not close list %s\n", $list->get_id;
                        exit 1;
                    }
                }
            }
            
        }elsif ($list_action->{'action'} eq 'NOTIFY') {
            $total_notifier++;
            unless ($options{'test'}) {
                my %admin = ();
                foreach my $role ('owner','editor') {
                    foreach my $user ($list->get_admins($role)) {
                        $admin{lc($user->{'email'})} = undef;
                    }
                }
                my @admin_array = uniq keys %admin;
                
                my $latest_mail = $list->get_latest_distribution_date() || 0;
                $latest_mail *= 86400;
                my $latest_formated ;
                if ($latest_mail) {
                    $latest_formated = POSIX::strftime("%d/%m/%Y", localtime($latest_mail));
                }else {
                    $latest_formated = 'never';
                }
                
                my $creation_date;
                if ($list->{'admin'}{'creation'} && $list->{'admin'}{'creation'}{'date_epoch'}) {
                    $creation_date = POSIX::strftime("%d/%m/%Y", localtime($list->{'admin'}{'creation'}{'date_epoch'}));
                }
                
                open SENDMAIL, "| /sbin/sendmail -f " . $confCleanup::notify_sender . " -- ".join(' ',@admin_array);
                my $template = Template->new(RELATIVE     => 1) || die "$Template::ERROR\n";
                my %param = ('to' => \@admin_array,
                             'list' => {
                                'name' => $listname,
                                'domain' => $listrobot,
                                'latest' => $latest_formated,
                                'creation' => $creation_date,
                                'members' => $list->get_total(),
                             },
                             'date_fermeture' => POSIX::strftime("%d/%m/%Y", localtime(time+(3600*24*30))),
                             );
                my $out;
                unless ($template->process($current_dir.'/mail_notif.tt2', \%param, \*SENDMAIL)) {
                    die "Failed to parse template '".$current_dir.'/mail_notif.tt2'."': ".$template->error();
                }
                close SENDMAIL;
            }
        }
    }
    
    printf "Closed lists : %d\n", $total_fermer;
    printf "Notified listowners : %d\n", $total_notifier;
        
}else {
    die "Missing argument";
}
