# Cleanup of inactive lists on a Sympa server

## Introduction

At University of Rennes 1, we built this process to detect inactive mailing lists and do some cleanup in our mailing lists server. It worked pretty well and we will probably run it yearly now.

## The process

1. detecting inactive/ead lists: the script loads all lists data to find inactive ones.
  * it checks:
    * latest distribution date,
    * if defined owners are valid addresses
    * creation date
    * number of list members
  * excluded from this process are:
    * lists attached to a family,
    * closed already lists,
    * lists included by another list,
    * lists tagged as "to_keep" (using custom_vars)
2. performing actions
  * low inactivity level: keep the list open,
  * medium inactivity level: notify list owners that we plan to close the list,
  * high inactivity level: close the list.
 
You will have to run the script 3 times and do some manual checks in the CSV file between runs.
 
## Installing the script

1. git clone this project on your Sympa server
2. `cp sample-confCleanup.pm confCleanup.pm` and customize it
3. cutomize location of Sympa installation : `use lib split(/:/, '/usr/local/sympa/bin' || '');`
4. install missing packages : ldapsearch
5. check the script executes : `./find_dead_lists.pl  --help`

## Running the process

### Find inactive lists

```
$ ./find_dead_lists.pl --check> inventory.csv
$ ./find_dead_lists.pl --prepare_cleanup --csv=inventory.csv > actions.csv
```

The `actions.csv` file will include the following actions:
* OK : no sign of inactivity
* KEEP : creation date too recent, keep the list
* VERIFY : requires manual check
* NOTIFY : notify list owners that we plan to close their list
* CLOSE : liste can be closed without notification


### Manual edition of actions.csv

Edit the `actions.csv`, having a closer look at VERIFY entries.

### Close or notify list owners

First check what the script plan to do:
`./find_dead_lists.pl --do_cleanup --test --csv=actions.csv`

Then run it for real:
`./find_dead_lists.pl --do_cleanup  --csv=actions.csv | tee cleanup.log`

### Manual edition of actions.csv, given list owners feedback

You might have 3 situations:
1. your notification bounced => either find valid listowners or plan to close that list
2. list owners confirm that you can close their list
3. list owners ask to keep their list open

For (3) you can tag these lists, adding a custom_var in that list config with var name `ur1_statut` and var value `garder`. The `./find_dead_lists.pl` will ignore these lists during later runs.

### Close lists, dependaing on list owners feedback

First check what the script plan to do:
`./find_dead_lists.pl --do_cleanup --test --csv=actions.csv`

Then run it for real:
`./find_dead_lists.pl --do_cleanup  --csv=actions.csv | tee cleanup.log`
