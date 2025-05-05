#!/bin/bash

# --- Configuration ---
# Original request used 'proftpd', you changed to 'root'.
# Using 'proftpd' is generally recommended for security (least privilege).
# If you MUST use 'root', ensure it's configured for unix_socket auth in MySQL.
DB_USER="root" # Use this line INSTEAD if you absolutely need to use root
DB_NAME="proftpd"
DEFAULT_SHELL="/sbin/nologin"
HOMEDIR_BASE="/home" # Base directory for user homes

# --- Function to display usage ---
usage() {
  echo "Usage: $0 --user=<username> --password=<password> --uid=<uid> --gid=<gid> --groupname=<groupname> --members=<members>"
  echo "  --user      : FTP username (mandatory)"
  echo "  --password  : FTP password (mandatory)"
  echo "  --uid       : User ID (numeric, mandatory)"
  echo "  --gid       : Group ID (numeric, mandatory)"
  echo "  --groupname : Primary group name for ftpgroup table (mandatory)"
  echo "  --members   : String for the 'members' column in ftpgroup (mandatory, often the username)"
  echo "  --homedir   : Optional home directory path (default: $HOMEDIR_BASE/<username>)"
  echo "  --shell     : Optional shell path (default: $DEFAULT_SHELL)"
  exit 1
}

# --- Parse command line arguments ---
FTP_USER=""
FTP_PASS=""
FTP_UID=""
FTP_GID=""
FTP_GROUPNAME=""
FTP_MEMBERS=""
FTP_HOMEDIR=""
FTP_SHELL="$DEFAULT_SHELL"

# Use getopt for robust argument parsing
OPTS=$(getopt -o h --long user:,password:,uid:,gid:,groupname:,members:,homedir:,shell:,help -n "$0" -- "$@")
if [ $? != 0 ]; then usage; fi

eval set -- "$OPTS"

while true; do
  case "$1" in
    --user ) FTP_USER="$2"; shift 2 ;;
    --password ) FTP_PASS="$2"; shift 2 ;;
    --uid ) FTP_UID="$2"; shift 2 ;;
    --gid ) FTP_GID="$2"; shift 2 ;;
    --groupname ) FTP_GROUPNAME="$2"; shift 2 ;;
    --members ) FTP_MEMBERS="$2"; shift 2 ;;
    --homedir ) FTP_HOMEDIR="$2"; shift 2 ;;
    --shell ) FTP_SHELL="$2"; shift 2 ;;
    -h | --help ) usage ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

# --- Validate mandatory arguments ---
if [ -z "$FTP_USER" ] || [ -z "$FTP_PASS" ] || [ -z "$FTP_UID" ] || [ -z "$FTP_GID" ] || [ -z "$FTP_GROUPNAME" ] || [ -z "$FTP_MEMBERS" ]; then
  echo "Error: Missing mandatory arguments."
  usage
fi

# --- Validate UID/GID are numeric ---
if ! [[ "$FTP_UID" =~ ^[0-9]+$ ]]; then
  echo "Error: UID must be numeric."
  usage
fi
if ! [[ "$FTP_GID" =~ ^[0-9]+$ ]]; then
  echo "Error: GID must be numeric."
  usage
fi

# --- Set default homedir if not provided ---
if [ -z "$FTP_HOMEDIR" ]; then
  FTP_HOMEDIR="$HOMEDIR_BASE/$FTP_USER"
fi

# --- Check for required tools ---
if ! command -v mysql &> /dev/null; then
    echo "Error: 'mysql' command not found. Please install the MySQL client."
    exit 1
fi
# Use mkpasswd for DES crypt
if ! command -v mkpasswd &> /dev/null; then
    echo "Error: 'mkpasswd' command not found."
    echo "Please install it. On Debian/Ubuntu: sudo apt update && sudo apt install whois"
    echo "On CentOS/RHEL/Fedora: sudo yum install expect"
    exit 1
fi


# --- Encrypt the password using DES-crypt via mkpasswd ---
# The '-m des' flag explicitly requests the traditional DES crypt algorithm.
echo "Encrypting password using DES crypt..."
ENCRYPTED_PASS=$(mkpasswd -m des "$FTP_PASS")
if [ $? -ne 0 ] || [ -z "$ENCRYPTED_PASS" ]; then
    echo "Error: Failed to encrypt password using mkpasswd."
    exit 1
fi

echo "--- Creating ProFTPD User ---"
echo "User       : $FTP_USER"
echo "UID        : $FTP_UID"
echo "GID        : $FTP_GID"
echo "Home Dir   : $FTP_HOMEDIR"
echo "Shell      : $FTP_SHELL"
echo "Group Name : $FTP_GROUPNAME"
echo "Members    : $FTP_MEMBERS"
# Do NOT echo the plain password or the hash unless debugging
# echo "Password Hash: $ENCRYPTED_PASS" # Uncomment for debugging ONLY

# --- Prepare SQL Statements ---
# Escape the password hash for SQL (though DES crypt output is usually safe)
# Basic escaping for single quotes:
SQL_SAFE_PASS=$(echo "$ENCRYPTED_PASS" | sed "s/'/''/g")

# Note: Using NOW() ensures the database server's current time is used.
SQL_USER_INSERT="INSERT INTO ftpuser (userid, passwd, uid, gid, homedir, shell, count, accessed, modified) VALUES ('$FTP_USER', '$SQL_SAFE_PASS', $FTP_UID, $FTP_GID, '$FTP_HOMEDIR', '$FTP_SHELL', 0, NOW(), NOW());"

SQL_GROUP_CHECK="SELECT id FROM ftpgroup WHERE groupname = '$FTP_GROUPNAME';"
SQL_GROUP_INSERT="INSERT INTO ftpgroup (groupname, gid, members) VALUES ('$FTP_GROUPNAME', $FTP_GID, '$FTP_MEMBERS');"

# --- Execute SQL ---

# Determine MySQL connection command based on DB_USER
if [ "$DB_USER" == "root" ]; then
    # Assuming root uses unix_socket or doesn't need a password prompt here
    MYSQL_CMD="mysql -u root"
    echo "Connecting to MySQL database '$DB_NAME' as user 'root' (using unix_socket)..."
else
    # Assuming proftpd user uses unix_socket
    MYSQL_CMD="mysql -u proftpd"
    echo "Connecting to MySQL database '$DB_NAME' as user 'proftpd' (using unix_socket)..."
fi


# Check if user already exists
EXISTING_USER_ID=$($MYSQL_CMD "$DB_NAME" -N -s -e "SELECT id FROM ftpuser WHERE userid = '$FTP_USER';" 2>&1)
MYSQL_EXIT_CODE=$?

if [ $MYSQL_EXIT_CODE -ne 0 ]; then
    echo "Error: Failed to query database for user check."
    echo "MySQL Error Output: $EXISTING_USER_ID" # Output contains error message here
    exit 1
fi

if [ -n "$EXISTING_USER_ID" ]; then
    echo "Error: User '$FTP_USER' already exists in the database (ID: $EXISTING_USER_ID)."
    exit 1
fi

# Check if group already exists
EXISTING_GROUP_ID=$($MYSQL_CMD "$DB_NAME" -N -s -e "$SQL_GROUP_CHECK" 2>&1)
MYSQL_EXIT_CODE=$?

if [ $MYSQL_EXIT_CODE -ne 0 ]; then
    echo "Error: Failed to query database for group check."
    echo "MySQL Error Output: $EXISTING_GROUP_ID" # Output contains error message here
    exit 1
fi

# Insert User
echo "Inserting user '$FTP_USER'..."
$MYSQL_CMD "$DB_NAME" -e "$SQL_USER_INSERT"
MYSQL_EXIT_CODE=$?

if [ $MYSQL_EXIT_CODE -ne 0 ]; then
    echo "Error: Failed to insert user '$FTP_USER' into database."
    # MySQL client often prints error messages automatically to stderr
    exit 1
else
    echo "User '$FTP_USER' inserted successfully."
fi

# Insert Group only if it doesn't exist
if [ -z "$EXISTING_GROUP_ID" ]; then
    echo "Group '$FTP_GROUPNAME' does not exist. Inserting group..."
    $MYSQL_CMD "$DB_NAME" -e "$SQL_GROUP_INSERT"
    MYSQL_EXIT_CODE=$?

    if [ $MYSQL_EXIT_CODE -ne 0 ]; then
        echo "Error: Failed to insert group '$FTP_GROUPNAME' into database."
        # Consider cleanup? Maybe remove the user? For simplicity, we don't here.
        exit 1
    else
        echo "Group '$FTP_GROUPNAME' inserted successfully."
    fi
else
     echo "Group '$FTP_GROUPNAME' already exists (ID: $EXISTING_GROUP_ID). Skipping group insertion."
     # You might want to update the 'members' field here if needed, but the request didn't specify this.
fi

echo "--- Operation Completed ---"
echo "Remember to create the actual home directory '$FTP_HOMEDIR' on the filesystem if it doesn't exist and set appropriate permissions."
exit 0