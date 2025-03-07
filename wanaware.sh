# Script to create the WanAware custom roles and service account
# The project to store the resources is the default per account

set -e

# Logging utilities
prefix="[ WanAware ]"

# Resource names
wanaware_role_name="WanAwareReadOnly"
serviceAccountId=$(echo "$wanaware_role_name" | tr '[:upper:]' '[:lower:]')
projectRole="${wanaware_role_name}ProjectRole"
organizationRole="${wanaware_role_name}OrganizationalRole"

# check google cloud shell
if ! command -v gcloud &>/dev/null; then
  printf "${prefix} [ERROR] Please run this script within a Google Cloud Console Shell,\n consult https://cloud.google.com/shell/docs/run-gcloud-commands for help\n"
  exit
fi

printf "${prefix} Getting project info...🔎 \n\n"

# get account's default project
projectId=$(
    gcloud config get-value project
)
if [ -z "${projectId}" ]
then
    printf "${prefix} The default project is unset, please check the configuration... \n\n"
    exit;
fi

# validate if the projectId is valid
# get project name
projectName=$(
  gcloud projects list --format="value(name)" --filter="id=$projectId"
)

# if, by mistake, the user set himself an invalid project, it won't be found
if [ -z "${projectName}" ]
then
    printf "${prefix} Project '${projectId}' is not found, please check the configuration... \n\n"
    exit;
fi

# Ask the user whether the service account will connect multiple projects
printf "\n${prefix} Will the service account connect multiple projects❓ [y/n] "
read multipleProjects;

printf "\n\n${prefix} Enabling services... \n"
gcloud services enable compute.googleapis.com cloudresourcemanager.googleapis.com admin.googleapis.com sqladmin.googleapis.com monitoring.googleapis.com cloudasset.googleapis.com --no-user-output-enabled
printf "${prefix} Necessary services enabled \n\n"

serviceAccountEmail="${serviceAccountId}@${projectId}.iam.gserviceaccount.com";

# get ancestors of the project
projectAncestorsInfo=$(gcloud projects get-ancestors $projectId --format='value[terminator="~",separator=","](type,id)')

# convert projectAncestorsInfo to array below
IFS='~'; read -r -a ancestorsArray <<< "$projectAncestorsInfo"

# iterate ancestors to get the organization
for ancestor in ${ancestorsArray[@]}; do
  IFS=','; read -r -a ancestorValues <<< "$ancestor";
  type=${ancestorValues[0]};
  if [ $type == "organization" ]; then
    organizationId=${ancestorValues[1]};
  fi
done

organizationName='No organization';
if [ -n "$organizationId" ]; then
  # get organization's name
  organizationName=$(
    gcloud organizations list --format="value(displayName)" --filter="name=organizations/$organizationId"
  )
fi

printf "${prefix} Creating resources at ${organizationName}/${projectName}... \n"

# *****************************
# START CREATING RESOURCES ==>
# *****************************

# ===========================
# Custom Project Role
# ===========================
printf "\n${prefix} Checking custom role...\n";

# Verify if the role exists already
projectRoleInfo=$(
    gcloud iam roles list --show-deleted --project=$projectId --filter="name=projects/${projectId}/roles/${projectRole}" --format="value[separator=','](name,deleted)"
);
if [ -z "${projectRoleInfo}" ]
then
    gcloud iam roles create $projectRole --project=$projectId --title="WanAware Read-Only Project Role" --description="Service Account for WanAware GCP Integrator to get read access to all project resources" --stage="GA"  --no-user-output-enabled;
else
    # check if the role is on deleted state
    IFS=','; read -r -a projectRoleArray <<< "$projectRoleInfo"
    isRoleDeleted=${projectRoleArray[1]};
    if [ -n "${isRoleDeleted}" ]
    then
        printf "${prefix} The role was deleted before, undeleting '${projectRole}' custom role to be available now...\n";
        gcloud iam roles undelete $projectRole --project=$projectId --no-user-output-enabled
    fi
fi
printf "${prefix} '${projectRole}' custom role has been created \n";

# Update permissions and stage
gcloud iam roles update $projectRole --project=$projectId --permissions="\
storage.buckets.get,\
storage.buckets.getIamPolicy" --no-user-output-enabled --stage=GA 

# ===========================
# Custom Organization Role
# ===========================
printf "\n${prefix} Checking organization role...\n";
# Verify if the role exists previously
organizationRoleInfo=$(
  gcloud iam roles list --show-deleted --organization=$organizationId --filter="name=organizations/${organizationId}/roles/${organizationRole}" --format="value[separator=','](name,deleted)"
);
if [ -z "${organizationRoleInfo}" ]
then
    gcloud iam roles create $organizationRole --organization=$organizationId --title="WanAware Read-Only Organizational Role" --description="Service Account with read-only access for WanAware GCP Integrator to get organizational IAM data." --stage="GA" --no-user-output-enabled
else
    # check if the role is on deleted state
    IFS=','; read -r -a organizationRoleArray <<< "$organizationRoleInfo"
    isRoleDeleted=${organizationRoleArray[1]};
    if [ -n "${isRoleDeleted}" ]
    then
        printf "${prefix} The role was deleted before, undeleting '${organizationRole}' custom role to be available now...\n";
        gcloud iam roles undelete $organizationRole --organization=$organizationId --no-user-output-enabled
    fi
fi
printf "${prefix} '${organizationRole}' organization role has been created \n";

# Update permissions and stage
gcloud iam roles update $organizationRole --organization=$organizationId --permissions="\
resourcemanager.organizations.getIamPolicy,\
storage.buckets.get,\
storage.buckets.getIamPolicy,\
resourcemanager.folders.get,\
resourcemanager.organizations.get,\
cloudasset.assets.searchAllResources" --no-user-output-enabled

# ===========================
# Service Account
# ===========================
printf "\n${prefix} Checking service account...\n";
# Check if the service account already exists
serviceAccountInfo=$(
  gcloud iam service-accounts list --filter="email=${serviceAccountEmail}" --format="value[separator=','](email,projectId)"
)
if [ -z "$serviceAccountInfo" ]
then
  gcloud iam service-accounts create ${serviceAccountId} --project="$projectId" --display-name="${serviceAccountId}" --description="Service Account with read-only access for WanAware GCP Integrator" --no-user-output-enabled;
  # Delay between the commands to allow propagation and avoid a NOT_FOUND error below
  printf "\n${prefix} Creating and propagating service account ⏱️\n\n";
  sleep 30;
else
  gcloud iam service-accounts update ${serviceAccountEmail} --project="$projectId" --display-name="${serviceAccountId}" --description="Service Account with read-only access for WanAware GCP Integrator" --no-user-output-enabled;
fi
printf "${prefix} '${serviceAccountId}' service account has been created 🚀\n";

# Force refresh the IAM Cache
gcloud projects get-iam-policy $projectId > /dev/null || printf "${prefix} Warning: Unable to force refresh IAM cache.";

# Create json key file
printf "\n${prefix} Generating json key file...\n";

tempFile=$(mktemp)
gcloud iam service-accounts keys create ./wanaware-key-file.json \
    --iam-account="${serviceAccountEmail}" \
    --project="$projectId" \
    --no-user-output-enabled >"$tempFile" 2>&1 || exitCode=$?

exitCode=${exitCode:-0}
errorMessage=$(<"$tempFile")
rm -f "$tempFile"
if [ $exitCode -ne 0 ]; then
    if echo "$errorMessage" | grep -q "Key creation is not allowed"; then
        printf "${prefix} Error: Key creation is not allowed. This may be due to a constraint policy, remove it and run this script again please. ❌\n\n";
    elif echo "$errorMessage" | grep -qE "MAX_KEYS_EXCEEDED|FAILED_PRECONDITION"; then
        printf "${prefix} Error: Too many keys. Please delete a key from the service account and try again. ❌\n\n";
    elif echo "$errorMessage" | grep -q "PERMISSION_DENIED"; then
        printf "${prefix} Error: You don't have the necessary permissions to create a key for this service account. ❌\n\n";
    elif echo "$errorMessage" | grep -q "NOT_FOUND"; then
        printf "${prefix} Warning: The specified service account does not exist. This may be due to cache issues, run this script again please. 🔄\n\n"
    else
        printf "${prefix} An unexpected error occurred. Details: $errorMessage ❌\n\n"
    fi
    exit $exitCode
else
    printf "${prefix} Key file has been generated 🚀\n\n"
fi

# ===========================
# Assignments
# ===========================   
# Assing project custom role
printf "${prefix} Assigning project custom role to service account...\n";
gcloud projects add-iam-policy-binding $projectId --member="serviceAccount:${serviceAccountEmail}" --role="projects/${projectId}/roles/${projectRole}" --no-user-output-enabled
# Assing organization custom role
printf "\n${prefix} Assigning organization custom role to service account...\n";
gcloud organizations add-iam-policy-binding $organizationId --member="serviceAccount:${serviceAccountEmail}" --role="organizations/${organizationId}/roles/${organizationRole}" --no-user-output-enabled
# Assing viewer/role to project
printf "\n${prefix} Assigning viewer/role to service account within the project...\n";
gcloud projects add-iam-policy-binding $projectId --member="serviceAccount:${serviceAccountEmail}" --role="roles/viewer" --no-user-output-enabled
if [ "$multipleProjects" != "n" -a "$multipleProjects" != "N" ]
then
  # Assing viewer/role to organization
  printf "\n${prefix} Assigning viewer/role to service account within the organization...\n";
  gcloud organizations add-iam-policy-binding $organizationId --member="serviceAccount:${serviceAccountEmail}" --role="roles/viewer" --no-user-output-enabled
else
  # if the user typed "No is multi project" then check if the viewer role is at the organization level and remove it
  removePolicy=$(
    gcloud organizations get-iam-policy $organizationId --format='value(bindings.members)' --flatten=bindings --filter="bindings.role:roles/viewer AND bindings.members ~ serviceAccount:${serviceAccountEmail}$"
  );
  # if the service account has the viewer role then delete the policy
  if [ -n "$removePolicy" ]
  then
    gcloud organizations remove-iam-policy-binding $organizationId --member="serviceAccount:${serviceAccountEmail}" --role="roles/viewer" --no-user-output-enabled;
  fi
fi

# ===========================
printf "\n${prefix} Done! Service Account '${serviceAccountId}' has been granted ✅\n"
# ===========================
