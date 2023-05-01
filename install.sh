#!/usr/bin/env bash

APP_NAME="quota-monitoring"
SVC_ACCT_NAME="$APP_NAME-sa"
CURRENT_USER=$(gcloud config get-value core/account)

function configure() {
    echo "Setting environment variables ..."

    read -p "Enter base domain for org (without .com) [example]: " DOMAIN
    DOMAIN=${DOMAIN:-example}
    echo "Domain: $DOMAIN"

    read -p "Enter project ID [$DOMAIN-$APP_NAME]: " PROJECT_ID
    PROJECT_ID=${PROJECT_ID:-$DOMAIN-$APP_NAME}
    echo "Project ID: $PROJECT_ID"

    read -p "Enter billing ID []: " BILLING_ID
    BILLING_ID=${BILLING_ID:-}
    echo "Billing ID: $BILLING_ID"

    read -p "Enter monitoring scope (org | folder) [org]: " SCOPE
    SCOPE=${SCOPE:-org}
    echo "Scope: $SCOPE"

    read -p "Enter region [us-central1]: " REGION
    REGION=${REGION:-us-central1}
    echo "Region: $REGION"

    read -p "Enter app engine location (us-central | europe-west) [us-central]: " AER
    GAE_REGION=${AER:-us-central}
    echo "App Engine location: $GAE_REGION"

    read -p "Confirm log bucket [$PROJECT_ID-alert-logs]: " BUCKET
    ALERT_LOG_BUCKET=${BUCKET:-$PROJECT_ID-alert-logs}
    echo "Alert log bucket: $ALERT_LOG_BUCKET"

    read -p "Confirm alert threshold percent [75]: " THRESHOLD
    ALERT_THRESHOLD=${THRESHOLD:-75}
    echo "Alert threshold percent: $ALERT_THRESHOLD"

    read -p "Confirm alert email destination [$CURRENT_USER]: " DEST
    ALERT_EMAIL=${DEST:-$CURRENT_USER}
    echo "Alert email destination: $ALERT_EMAIL"

    SVC_ACCT_EMAIL="$SVC_ACCT_NAME@$PROJECT_ID.iam.gserviceaccount.com"
    echo "Service account: $SVC_ACCT_EMAIL"

    setup_project
}

function setup_project() {
    echo "Configuring environment ..."

    MSG_BILLING_ERROR="Error linking billing. It should be like (XXXXXX-XXXXXX-XXXXXX). Try again."

    echo "Enabling APIs ..."
    gcloud services enable compute.googleapis.com \
        storage.googleapis.com \
        run.googleapis.com \
        bigquery.googleapis.com \
        cloudbuild.googleapis.com \
        artifactregistry.googleapis.com \
        cloudfunctions.googleapis.com \
        cloudscheduler.googleapis.com \
        appengine.googleapis.com \
        pubsub.googleapis.com \
        monitoring.googleapis.com \
        logging.googleapis.com
    
    echo "Configuring SDK ..."
    gcloud config set compute/region $REGION

    echo "Creating project and linking billing ..."
    gcloud projects create $PROJECT_ID && echo "Project created" || echo "Project exists. Continuing ..."
    PROJECT_ID=$(gcloud config get-value project)   # GCP may append random chars if not unique
    gcloud beta billing projects link --billing-account=$BILLING_ID $PROJECT_ID || { echo $MSG_BILLING_ERROR ; exit 1; }
    gcloud config set core/project $PROJECT_ID

    echo "Creating service account ($SVC_ACCT_NAME) ..."
    gcloud iam service-accounts create $SVC_ACCT_NAME \
        --description="Service Account to scan quota usage" \
        --display-name=$SVC_ACCT_NAME || echo "Service account exists. Continuing ..."
    
    echo "Assigning IAM roles to service account ..."
    declare -a HOST_SA_ROLES=("bigquery.dataEditor" 
        "bigquery.jobUser" "cloudfunctions.admin" "cloudscheduler.admin" 
        "pubsub.admin" "iam.serviceAccountUser" "storage.admin" 
        "serviceusage.serviceUsageAdmin" "cloudasset.viewer" "compute.networkViewer" 
        "compute.viewer" "monitoring.notificationChannelEditor" 
        "monitoring.alertPolicyEditor" "logging.configWriter" 
        "logging.logWriter" "monitoring.viewer" "monitoring.metricWriter" 
        "iam.securityAdmin")

    for val in ${HOST_SA_ROLES[@]}; do
    gcloud projects add-iam-policy-binding $PROJECT_ID \
        --member="serviceAccount:$SVC_ACCT_EMAIL" \
        --role="roles/$val" --condition=None
    done

    setup_target
}

function setup_target() {
    echo "Configuring target permissions for monitoring ..."

    # fetch org and folder associated to current project as defaults
    FOLDER_ID=$(gcloud projects get-ancestors $PROJECT_ID --format="value(id)" | sed -n 2p)
    ORG_ID=$(gcloud projects get-ancestors $PROJECT_ID --format="value(id)" | tail -n 1)
    if [ $SCOPE = "folder" ]; then
        TARGET_ID=$FOLDER_ID
    else
        TARGET_ID=$ORG_ID
    fi

    # confirm default target scope or override
    read -p "Confirm target $SCOPE [$TARGET_ID]: " TARGET
    TARGET_ID=${TARGET:-$TARGET_ID}
    echo "Target $SCOPE: $TARGET_ID"

    declare -a TARGET_ROLES=("cloudasset.viewer" "compute.networkViewer" 
        "compute.viewer" "resourcemanager.folderViewer" "monitoring.viewer")

    if [ $SCOPE = "folder" ]; then
        for val in ${TARGET_ROLES[@]}; do
        gcloud alpha resource-manager folders add-iam-policy-binding $TARGET_ID \
            --member="serviceAccount:$SVC_ACCT_EMAIL" \
            --role="roles/$val" --condition=None
        done
    else
        for val in ${TARGET_ROLES[@]}; do
        gcloud organizations add-iam-policy-binding $TARGET_ID \
            --member="serviceAccount:$SVC_ACCT_EMAIL" \
            --role="roles/$val" --condition=None
        done        
    fi

    setup_qms
}

function setup_qms() {
    echo "Configuring quota monitoring solution (QMS) ..."

    BASE_DIR=$(PWD)     # for returning later
    QMS_DIR="quota-monitoring-solution"
    QMS_TF_DIR="terraform/example"
    QMS_TF_VAR_FILE="terraform.tfvars"
    QMS_TF_MAIN_FILE="main.tf"
    QMS_TF_CREDS="credentials"  
    SCHEDULER_MONITORING_JOB="quota-monitoring-cron-job"
    SCHEDULER_ALERT_JOB="quota-monitoring-app-alert-config"

    echo "Creating AppEngine app for cloud scheduler ..."
    gcloud app create --region=$GAE_REGION || echo "App Engine app exists. Continuing ..."

    # check if git repo folder exists and decide to overwrite
    if [ -d $QMS_DIR ]; then
        echo "Directory $QMS_DIR exists. Overwrite?"
        select yn in "Yes" "No"; do
            case $yn in
                Yes ) rm -rf $QMS_DIR; download_git_repo; break;;
                No ) break;;
            esac
        done
    else
        download_git_repo
    fi

    echo "Configuring Terraform defaults (you can manually edit and re-run in future) ..."
cat > $QMS_DIR/$QMS_TF_DIR/$QMS_TF_VAR_FILE << EOF
project_id                 = "$PROJECT_ID"
region                     = "$GAE_REGION"
service_account_email      = "$SVC_ACCT_EMAIL"
folders                    = "[]"
organizations              = "[]"
alert_log_bucket_name      = "$ALERT_LOG_BUCKET"
notification_email_address = "$ALERT_EMAIL"
threshold                  = "$ALERT_THRESHOLD"
EOF

    # override config file with target org or folder ID
    if [ $SCOPE = "folder" ]; then
        sed -i.bak "s/folders.*/folders                    = \"[$TARGET_ID]\"/g" $QMS_DIR/$QMS_TF_DIR/$QMS_TF_VAR_FILE
    else
        sed -i.bak "s/organizations.*/organizations              = \"[$TARGET_ID]\"/g" $QMS_DIR/$QMS_TF_DIR/$QMS_TF_VAR_FILE
    fi

    prompt_terraform_install
}

function download_git_repo() {
    echo "Fetching source code to configure ..."
    git clone https://github.com/google/quota-monitoring-solution.git $QMS_DIR
}

function prompt_terraform_install() {
cat << EOF

-------------------------------

Congratulations! You are now ready to apply your Terraform code.

First, impersonate your service account for short-lived oauth token:
> gcloud config set auth/impersonate_service_account $SVC_ACCT_EMAIL

Next, set ENV var for terraform authentication:
> export GOOGLE_OAUTH_ACCESS_TOKEN=\$(gcloud auth print-access-token)

Next, change to the example terraform directory:
> cd $BASE_DIR/$QMS_DIR/$QMS_TF_DIR

Next, run terraform (if errors re-run terraform plan and terraform apply)
> terraform init
> terraform plan
> terraform apply  [choose 'yes']

Once the QMS app is installed, stop impersonating service account:
> gcloud config unset auth/impersonate_service_account

Return to the assets directory:
> cd $BASE_DIR

Then, start the scheduler jobs (and wait 10-20 minutes before data appears):
> gcloud scheduler jobs run $SCHEDULER_MONITORING_JOB --location $REGION
> gcloud scheduler jobs run $SCHEDULER_ALERT_JOB --location $REGION

Finally, revisit the documentation to set up your Looker Studio dashboard:
- https://github.com/google/quota-monitoring-solution#310-data-studio-dashboard-setup

-------------------------------

( follow instructions above to finish installation )

EOF
}

# confirm install, then proceed
echo "Do you wish to install quota monitoring solution?"
select yn in "Yes" "No"; do
    case $yn in
        Yes ) configure; break;;
        No ) exit;;
    esac
done
