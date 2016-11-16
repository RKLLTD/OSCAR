#!/bin/bash
#
set -e # exit on errors
#
echo -n "Enter Oscar password: "
read oscar_passwd
echo "Create Oscar database with password $oscar_passwd"
#

echo "Installing MySQL..."
cd $HOME
# install MySQL
if [ ! -d /var/lib/mysql ]
then
  sudo apt-get --yes install mysql-server libmysql-java
fi
#

echo "Setting up JAVA_HOME..."
# setup JAVA_HOME
if ! grep --quiet "JAVA_HOME" /etc/environment
then
  sudo bash -c 'echo JAVA_HOME=\"/usr/lib/jvm/java-8-oracle\" >> /etc/environment'
fi
export JAVA_HOME="/usr/lib/jvm/java-8-oracle"

echo "Setting up TOMCAT and MAVEN..."
#
# install Tomcat and Maven
if ! grep --quiet "CATALINA_BASE" /etc/environment
then
  sudo apt-get --yes install tomcat7 maven git-core lynx
  #
  # set up Tomcat's deployment environment
  # Do not indent body of HERE document!
  sudo bash -c "cat  >> /etc/environment" <<'EOF'
CATALINA_HOME="/usr/share/tomcat7"
CATALINA_BASE="/var/lib/tomcat7"
ANT_HOME="/usr/share/ant"
EOF
#
fi
#
grep -v PATH /etc/environment >> ~/.bashrc
echo "export JAVA_HOME CATALINA_HOME CATALINA_BASE ANT_HOME" >> ~/.bashrc
source ~/.bashrc
export CATALINA_HOME="/usr/share/tomcat7"
export CATALINA_BASE="/var/lib/tomcat7"

echo "Setting up CATALINA_BASE..."

if [ -z "$CATALINA_BASE" ]
then
  echo "Failed to configure CATALINA_BASE in /etc/environment.  Exiting..."
  exit
fi

#echo "Setting up JAVA alterantives..."
#
#sudo update-alternatives --config java
#sudo update-alternatives --config javac
#sudo update-alternatives --config javaws
#

echo "Intalling OSCAR..."
# install Oscar
if [ ! -d $HOME/git ]
then
  mkdir $HOME/git
fi
cd $HOME/git
#
# retrieve Oscar from github
if [ ! -d ./oscar ]
then
  git clone git://github.com/scoophealth/oscar.git
fi
if [ ! -d ./oscar ]
then
  exit
fi
cd ./oscar
git fetch origin
git checkout master

echo '  cloned...'
#
# build Oscar from source
export CATALINA_HOME
#
# This shouldn't be necessary but required in most recent deploys to avoid
# missing dependencies
mkdir -p ~/.m2/repository
rsync -av $HOME/git/oscar/local_repo/ $HOME/.m2/repository/
#

echo '  maven m2 setup...'

if [ ! -f $CATALINA_BASE/webapps/oscar14.war ]
then
  echo '  about to build oscar...'
  mvn -Dmaven.test.skip=true clean verify
  sudo cp ./target/*.war $CATALINA_BASE/webapps/oscar14.war
  #
  # build oscar_documents from source
  cd $HOME/git
  if [ ! -d ./oscar_documents ]
  then
    git clone git://oscarmcmaster.git.sourceforge.net/gitroot/oscarmcmaster/oscar_documents
  else
    cd ./oscar_documents
    git pull
  fi
  cd $HOME/git
  if [ ! -d ./oscar_documents ]
  then
    exit
  fi
  cd ./oscar_documents
  mvn -Dmaven.test.skip=true clean package
  sudo cp ./target/*.war $CATALINA_BASE/webapps/OscarDocument.war
fi

echo 'OSCAR INSTALLED'
#
# create oscar database
cd $HOME/git/oscar/database/mysql

if sudo bash -c '[[ ! -d "/var/lib/mysql/oscar_14" ]]'#run under a subshell
then 
  echo "Setting up DATABASE"
  export PASSWORD=$oscar_passwd
  ./createdatabase_bc.sh root $PASSWORD oscar_14
  #
  
  echo "FINISHED WITH DATABASE STUFF"; 
  cd $HOME
  if [ ! -f $CATALINA_HOME/oscar14.properties ]
  then
    echo "Setting up OSCAR PROPERTIES..."
    if [ ! -f ./devops/Setup/oscar14-env-bc-subs.sed ]
    then
      echo "ERROR: sedscript is missing!"
      exit
    fi
    echo "  found sed script..."
    sed -f ./devops/Setup/oscar14-env-bc-subs.sed < $HOME/git/oscar/src/main/resources/oscar_mcmaster.properties > /tmp/oscar14.properties
    echo "  edited sed script and pushed to tmp/oscar14.properties..."
    echo "ModuleNames=E2E" >> /tmp/oscar14.properties
    echo "E2E_URL = http://localhost:3001/records/create" >> /tmp/oscar14.properties
    echo "E2E_DIFF = off" >> /tmp/oscar14.properties
    echo "E2E_DIFF_DAYS = 14" >> /tmp/oscar14.properties
    echo "drugref_url=http://localhost:8080/drugref/DrugrefService" >> /tmp/oscar14.properties
    sed --in-place "s/db_password=xxxx/db_password=$oscar_passwd/" /tmp/oscar14.properties
    sudo cp /tmp/oscar14.properties $CATALINA_HOME/
  else
    echo "Found OSCAR PROPERTIES"
  fi
else
  echo 'Database already exists. Skipped creation.';
fi

if [ ! -f /etc/default/tomcat7 ]
then
  echo "Tomcat7 is not installed!"
  exit
fi
sudo sed --in-place 's/JAVA_OPTS.*/JAVA_OPTS="-Djava.awt.headless=true -Xmx1024m -Xms1024m -XX:MaxPermSize=512m -server"/' /etc/default/tomcat7
#
# tweak MySQL server
cd $HOME/git/oscar/database/mysql
java -cp .:$HOME/git/oscar/local_repo/mysql/mysql-connector-java/3.0.11/mysql-connector-java-3.0.11.jar importCasemgmt $CATALINA_HOME/oscar14.properties
#
mysql -uroot -p$oscar_passwd -e 'insert into issue (code,description,role,update_date,sortOrderId) select icd9.icd9, icd9.description, "doctor", now(), '0' from icd9;' oscar_14
#
# import and update drugref
cd $HOME/git
wget --secure-protocol=sslv3 --no-check-certificate  https://demo.oscarmcmaster.org:11042/job/drugref2Master/lastSuccessfulBuild/artifact/target/drugref2.war
sudo mv drugref2.war $CATALINA_BASE/webapps/drugref2.war
#
# Do not indent body of HERE document!
sudo bash -c "cat  >> $CATALINA_HOME/drugref2.properties" <<'EOF'
db_user=root
db_password=xxxx
db_url=jdbc:mysql://127.0.0.1:3306/drugref2
db_driver=com.mysql.jdbc.Driver
EOF
#
sudo sed --in-place "s/db_password=xxxx/db_password=$oscar_passwd/" $CATALINA_HOME/drugref2.properties
#
if sudo -c '[[ ! -d /var/lib/mysql/drugref2]]'
then 
# create a new database to hold the drugref.
mysql -uroot -p$oscar_passwd -e "CREATE DATABASE drugref2;"
else
  echo 'The DrugRef2 Database aldready exists --- not recreating it'
fi
#
# To apply all the changes to the Tomcat server, we need to restart it
sudo /etc/init.d/tomcat7 restart
#
echo "loading drugref database..."
echo "This takes 15 minutes to 1 hour"
lynx http://localhost:8080/drugref/Update.jsp
