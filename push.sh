#!/bin/sh

# TBD: Should take as an argument a command to execute, e.g. update
# web2py without touch neo4j, or vice versa, or upload a new version
# of a database.

# You may wonder about my use of $foo vs. ${foo} vs. "$foo" vs. "${foo}".
# It's basically random.  I'm expecting to come up with some rules for
# choosing between these any day now.
# As far as I can tell, you use {} in case of concatenation with a
# letter or digit, and you use "" to protect against the possibility
# of there being a space in the variable value.

set -e

# $0 -h <hostname> -u <username> -i <identityfile> -n <hostname>

# The host must always be specified
# OPENTREE_HOST=dev.opentreeoflife.org
# OPENTREE_NEO4J_HOST=dev.opentreeoflife.org
OPENTREE_ADMIN=admin
OPENTREE_IDENTITY=opentree.pem
OPENTREE_DOCSTORE=treenexus
OPENTREE_GH_IDENTITY=opentree-gh.pem
OPENTREE_COMPONENTS=most
DRYRUN=no

if [ x$CONTROLLER = x ]; then
    CONTROLLER=`whoami`
fi

# On ubuntu, the admin user is called 'ubuntu'

while [ $# -gt 0 ]; do
    if [ ${1:0:1} != - ]; then
	break
    fi
    flag=$1
    shift
    if [ "x$flag" = "x-c" ]; then
	# Config file overrides default parameter settings
        source "$1"; shift
    elif [ "$flag" = "--dry-run" ]; then
	DRYRUN=yes
    # The following are all legacy; do not add cases to this 'while'.
    # Configuration should now be done in the config file.
    elif [ "x$flag" = "x-h" ]; then
	OPENTREE_HOST="$1"; shift
    elif [ "x$flag" = "x-p" ]; then
	OPENTREE_PUBLIC_DOMAIN="$1"; shift
    elif [ "x$flag" = "x-u" ]; then
	OPENTREE_ADMIN="$1"; shift
    elif [ "x$flag" = "x-i" ]; then
	OPENTREE_IDENTITY="$1"; shift
    elif [ "x$flag" = "x-n" ]; then
	OPENTREE_NEO4J_HOST="$1"; shift
    else
	echo 1>&2 "Unrecognized flag: $flag"
	exit 1
    fi
done

[ "x$OPENTREE_HOST" != x ] || (echo "OPENTREE_HOST not specified"; exit 1)
[ -r $OPENTREE_IDENTITY ] || (echo "$OPENTREE_IDENTITY not found"; exit 1)
[ "x$OPENTREE_NEO4J_HOST" != x ] || OPENTREE_NEO4J=$OPENTREE_HOST
[ "x$OPENTREE_PUBLIC_DOMAIN" != x ] || OPENTREE_PUBLIC_DOMAIN=$OPENTREE_HOST

# abbreviations... no good reason for these, they just make the commands shorter
ADMIN=$OPENTREE_ADMIN
NEO4JHOST=$OPENTREE_NEO4J_HOST

SSH="ssh -i ${OPENTREE_IDENTITY}"

# For unprivileged actions
OT_USER=opentree

echo "host=$OPENTREE_HOST, admin=$ADMIN, pem=$OPENTREE_IDENTITY, controller=$CONTROLLER, command=$command"

restart_apache=no

function docommand {

    if [ $# -eq 0 ]; then
	if [ $DRYRUN = yes ]; then echo "[no command]"; fi
	for component in $OPENTREE_COMPONENTS; do
	    docommand $component
	done
	return
    fi

    command="$1"
    shift
    case $command in
	# Legacy default
        most  | all | push | pushmost)
	    if [ $DRYRUN = yes ]; then echo "[all]"; fi
    	    push_opentree
    	    push_all_neo4j
	    restart_apache=yes
    	    ;;
	# Components
	opentree  | push-web2py)
            push_opentree
	    restart_apache=yes
	    ;;
	api  | push-api | push_api)
	    # Does this work without a prior push_opentree? ... maybe not.
            push_api; restart_apache
	    ;;
	oti)
            push_neo4j oti
	    ;;
	treemachine)
            push_neo4j treemachine
	    ;;
	taxomachine)
            push_neo4j taxomachine
	    ;;

	none)
	    echo "No components specified.  Try configuring OPENTREE_COMPONENTS"
	    ;;
	push-db | pushdb)
	    push_db $*
    	    ;;
	index  | indexoti | index-db)
	    index
    	    ;;
	echo)
	    # Test ability to do remote commands inline...
	    ${SSH} "$OT_USER@$OPENTREE_HOST" bash <<EOF
 	        echo $*
EOF
	    ;;
	*)
	    echo "Unrecognized command: $command"
	    ;;
    esac 
}

function sync_system {
    echo "Syncing"
    if [ $DRYRUN = "yes" ]; then echo "[sync]"; return; fi
    # Do privileged stuff
    # Don't use rsync - might not be installed yet
    scp -p -i "${OPENTREE_IDENTITY}" as-admin.sh "$ADMIN@$OPENTREE_HOST":
    ${SSH} "$ADMIN@$OPENTREE_HOST" ./as-admin.sh "$OPENTREE_HOST"
    # Copy files over
    rsync -pr -e "${SSH}" "--exclude=*~" "--exclude=#*" setup "$OT_USER@$OPENTREE_HOST":
    }

function push_all_neo4j {
    if [ $DRYRUN = "yes" ]; then echo "[all neo4j apps]"; return; fi
    ${SSH} "$OT_USER@$OPENTREE_HOST" ./setup/install-neo4j-apps.sh $CONTROLLER
}

function push_neo4j {
    if [ $DRYRUN = "yes" ]; then echo "[neo4j app: $1]"; return; fi
    ${SSH} "$OT_USER@$OPENTREE_HOST" ./setup/install-neo4j-apps.sh $CONTROLLER $1
}

function restart_apache {
    if [ $DRYRUN = "yes" ]; then echo "[restarting apache]"; return; fi
    # The install scripts modify the apache config file, so do this last
    ${SSH} "$ADMIN@$OPENTREE_HOST" \
      sudo cp -p "~$OT_USER/setup/apache-config" /etc/apache2/sites-available/opentree
    echo "Restarting apache httpd..."
    ${SSH} "$ADMIN@$OPENTREE_HOST" sudo apache2ctl graceful
}

function push_opentree {
    if [ $DRYRUN = "yes" ]; then echo "[opentree]"; return; fi
    ${SSH} "$OT_USER@$OPENTREE_HOST" ./setup/install-web2py-apps.sh "$OPENTREE_HOST" "${OPENTREE_PUBLIC_DOMAIN}" "${NEO4JHOST}" $CONTROLLER
    # place the file with secret Janrain key
    keyfile=../webapp/private/janrain.key
    if [ -r $keyfile ]; then
        rsync -pr -e "${SSH}" $keyfile "$OT_USER@$OPENTREE_HOST":repo/opentree/webapp/private/janrain.key
    else
	echo "Cannot find janrain key file $keyfile"
    fi
}

function push_api {
    echo "doc store is $OPENTREE_DOCSTORE"
    if [ $DRYRUN = "yes" ]; then echo "[api]"; return; fi
    rsync -pr -e "${SSH}" $OPENTREE_GH_IDENTITY "$OT_USER@$OPENTREE_HOST":.ssh/opentree
    ${SSH} "$OT_USER@$OPENTREE_HOST" chmod 600 .ssh/opentree
    ${SSH} "$OT_USER@$OPENTREE_HOST" ./setup/install-api.sh "$OPENTREE_HOST" $OPENTREE_DOCSTORE $CONTROLLER
}

function index {
    if [ $DRYRUN = "yes" ]; then echo "[index]"; return; fi
    ${SSH} "$OT_USER@$OPENTREE_HOST" ./setup/index-doc-store.sh $OPENTREE_DOCSTORE $CONTROLLER
}

function push_db {
    if [ $DRYRUN = "yes" ]; then echo "[push_db]"; return; fi
    # Work in progress - code not yet enabled
    # E.g. ./push.sh push-db localnewdb.db.tgz taxomachine
    TARBALL=$1
    APP=$2
    rsync -vax -e "${SSH}" $TARBALL "$OT_USER@$OPENTREE_HOST":downloads/$APP.db.tgz
    ${SSH} "$OT_USER@$OPENTREE_HOST" ./setup/install-db.sh "$OPENTREE_HOST" $APP $CONTROLLER
}

sync_system
docommand $*
if [ $restart_apache = "yes" ]; then
    restart_apache
fi

# Test: 
# Ubuntu micro:
#  open http://ec2-54-202-160-175.us-west-2.compute.amazonaws.com/
# Debian small:
#  open http://ec2-54-202-237-199.us-west-2.compute.amazonaws.com/
