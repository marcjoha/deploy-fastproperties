<#
.SYNOPSIS
Deploys properties on a local FAST Search for SharePoint farm.
 
.DESCRIPTION
In FAST Search for SharePoint, the index schema is represented
by a set of 'managed properties' populated with content by
being mapped to a set of 'crawled properties'. This cmdlet
alleviates deployment and management of said properties by
allowing you to specify managed properties, crawled properties,
and crawled property mappings in a readable XML format.

You can use the -GenerateExampleSchema switch to generate
a sample XML file.

Warning:
Use this script on your own risk. Although modifying the index
schema is generally safe, many changes require your index to be
recrawled, and in worst case may leave your index corrupt.

Note:
There are some additional settings you can set on managed
properties that aren't covered by this script. See the help
for the cmdlet Get-FASTSearchMetadataManagedProperty for a
complete list of all properties.

.PARAMETER SchemaFile
Path to the XML file defining the properties to deploy
 
.PARAMETER Undeploy
Reverse effect! Attempts to undeploy properties.

.PARAMETER GenerateExampleSchema
Generates an example of a valid schema file
 
.EXAMPLE 
Deploy-FastIndexSchema -SchemaFile .\schema.xml

Deploys the FAST properties specified in 'schema.xml'

.EXAMPLE 
Deploy-FastIndexSchema -SchemaFile .\schema.xml -Undeploy

Attemps to undeploy all properties and categories as specified in 'schema.xml'

.EXAMPLE 
Deploy-FastIndexSchema -GenerateExampleSchema | Out-File temp.xml

Generate an example of a valid schema file and store it in 'temp.xml'

.NOTES
Author:	Marcus Johansson (@marcjoha)

.LINK
http://github.com/marcjoha

#>

Param(
	[ValidateScript({Test-Path -PathType 'Leaf' $_})]
	[Parameter(ParameterSetName="normalprocessing", Mandatory=$true, Position=1)]
	[String]$SchemaFile = $(throw "Parameter -SchemaFile is required")
	,
	[Parameter(ParameterSetName="normalprocessing")]
	[Switch]$Undeploy
	,
	[Parameter(ParameterSetName="example")]
	[Switch]$GenerateExampleSchema	
)

# Constants
Set-Variable booleans -Option Constant -Value @{true = $true; false = $false}
Set-Variable cpTypes -Option Constant -Value @{boolean = 11; datetime = 64; decimal = 5; integer = 20; text = 31}
Set-Variable mpTypes -Option Constant -Value @{boolean = 3; datetime = 6; decimal = 5; float = 4; integer = 2; text = 1}
Set-Variable sortTypes -Option Constant -Value @{disabled = 0; enabled = 1; latent = 2}
Set-Variable summaryTypes -Option Constant -Value @{disabled = 0; static = 1; dynamic = 2}

# Cached data
$propsetCache = @{}

# INTERNAL FUNCTIONS

function DeployFullTextIndex([String]$Name="", [String]$Description="", [Boolean]$Stemming=$true) {
	
	# If $Name is omitted, the default fti is used
	if($Name -eq "") {
		$fti = Get-FASTSearchMetadataFullTextIndex | Where-Object { $_.isDefault -eq $true }
		if(($fti | Measure-Object).Count -ne 1) {
			Write-Error "Couldn't locate the default full-text index" -ErrorAction Stop
		} else {
			$Name = $fti.Name
		}
	}
	
	Write-Host ("Deploying full-text index '{0}'" -f $Name)
	
	# Get or create the full-text index
	$fti = $null
	$fti = Get-FASTSearchMetadataFullTextIndex -Name $Name
	if($fti -ne $null) {
		Write-Verbose ("Full-text index '{0}' already exists" -f $Name)
	} else {
		# Empty description is not allowed
		if($Description -eq "") {
			$Description = "Full-text index {0}" -f $Name
		}
	
		$fti = New-FASTSearchMetadataFullTextIndex -Name $Name -Description $Description
		Write-Verbose ("Successfully created full-text index '{0}'" -f $Name)
	}
	
	# Attempt to update the full-text index with any optional settings
	$appliedChange = $false
	if($fti.Description -ne $Description)  {
		Write-Verbose ("Setting 'Description' to '{0}'" -f $Description)
		$fti.Description = $Description
		$appliedChange = $true
	}
	if($fti.StemmingEnabled -ne $Stemming)  {
		Write-Verbose ("Setting 'StemmingEnabled' to '{0}'" -f $Stemming)
		$fti.StemmingEnabled = $Stemming
		$appliedChange = $true
	}	

	# Sum up info for the user
	if($appliedChange) {
		Write-Verbose "Update in progress..."
		$fti.Update()
	} else {
		Write-Verbose "No optional settings were updated"
	}	
	
	return $fti
}

function RemoveFullTextIndex([String]$Name) {
	Write-Host ("Removing full-text index '{0}'" -f $Name)
		
	$fti = Get-FASTSearchMetadataFullTextIndex -Name $Name
	if($managedProperty -eq $null) {
		Write-Verbose ("The full-text index '{0}' does not exist" -f $Name)
	} else {
		if($fti.isDefault) {
			Write-Verbose ("Won't remove default full-text index '{0}'" -f $Name)
		} else {
			Remove-FASTSearchMetadataFullTextIndex -Name $Name -Force
			Write-Verbose "Successfully removed full-text index"
		}
	}
}

function DeployManagedProperty([String]$Name,
							   [String]$Type,
							   [Object]$Fti,
							   [String]$Description="", 
							   [int]$Level=0,
							   [Boolean]$Query=$true, 
							   [Boolean]$Refine=$false, 
							   [Boolean]$Stemming=$false, 
							   [Boolean]$Merge=$false, 
							   [String]$Sort="disabled", 
							   [String]$Summary="static") {
	
	Write-Host ("Deploying managed property '{0}'" -f $Name)

	# Verification: The type must be one of those in $mpTypes
	if(!$mpTypes.ContainsKey($Type)) {
		Write-Error ("The type '{0}' used in the definition of managed property '{1}' is incorrect. The type needs to be one of '{2}'." -f $Type, $Name, [String]::Join(", ", $mpTypes.keys)) -ErrorAction Stop
	}
	
	# Verification: If important level is specified it must be in the range 0-7 (0 means no FTI mapping at all)
	if(($Level -lt 0) -or ($Level -gt 7)) {
		Write-Error ("The importance level '{0}' used in the definition of managed property '{1}' is incorrect. The level needs to be in the range 0-7." -f $Level, $Name) -ErrorAction Stop
	}		
	
	# Verification: If sort type is specified it must be one of those in $sortTypes
	if(!$sortTypes.ContainsKey($Sort)) {
		Write-Error ("The sort type '{0}' used in the definition of managed property '{1}' is incorrect. The sort type needs to be one of '{2}'." -f $Sort, $Name, [String]::Join(", ", $sortTypes.keys)) -ErrorAction Stop
	}

	# Verification: If summary type is specified it must be one of those in $sortTypes
	if(!$summaryTypes.ContainsKey($Summary)) {
		Write-Error ("The summary type '{0}' used in the definition of managed property '{1}' is incorrect. The summary type needs to be one of '{2}'." -f $Summary, $Name, [String]::Join(", ", $summaryTypes.keys)) -ErrorAction Stop
	}
		
	# Get or create the managed property
	$managedProperty = Get-FASTSearchMetadataManagedProperty -Name $Name
	if($managedProperty -ne $null) {
		Write-Verbose ("Managed property '{0}' already exists" -f $Name)

        # If the property already exist, but with a different type. Flag error and exit, as it's impossible to resolve automatically
        if($managedProperty.Type -ne $Type) {
            Write-Error ("The managed property '{0}' already exists, but with a different type. FAST does not allow to change a property's type, without deleting and recreating it. Please do this manually." -f $Name) -ErrorAction Stop
        }

	} else {	
		$managedProperty = New-FASTSearchMetadataManagedProperty -Name $Name -Type $mpTypes[$Type] -Description $Description
		Write-Verbose ("Successfully created managed property '{0}'" -f $Name)
	}
	
	# Attempt to update the managed property with any optional settings
	$appliedChange = $false
	if($managedProperty.Description -ne $Description)  {
		Write-Verbose ("Setting 'Description' to '{0}'" -f $Description)
		$managedProperty.Description = $Description
		$appliedChange = $true
	}	    
	if($managedProperty.SortableType -ne $sortTypes[$Sort])  {
		Write-Verbose ("Setting 'SortableType' to '{0}'" -f $Sort)
		$managedProperty.SortableType = $sortTypes[$Sort]
		$appliedChange = $true
	}
	if($managedProperty.Queryable -ne $Query) {
		Write-Verbose ("Setting 'Queryable' to '{0}'" -f $Query)
		$managedProperty.Queryable = $Query
		$appliedChange = $true
	}
	if($managedProperty.RefinementEnabled -ne $Refine) {
		Write-Verbose ("Setting 'RefinementEnabled' to '{0}'" -f $Refine)
		$managedProperty.RefinementEnabled = $Refine
		$appliedChange = $true
	}
	if($managedProperty.StemmingEnabled -ne $Stemming) {
		Write-Verbose ("Setting 'StemmingEnabled' to '{0}'" -f $Stemming)
		$managedProperty.StemmingEnabled = $Stemming
		$appliedChange = $true
	}	
	if($managedProperty.MergeCrawledProperties -ne $Merge) {
		Write-Verbose ("Setting 'MergeCrawledProperties' to '{0}'" -f $Merge)
		$managedProperty.MergeCrawledProperties = $Merge
		$appliedChange = $true
	}	
	if($managedProperty.SummaryType -ne $summaryTypes[$Summary])  {
		Write-Verbose ("Setting 'SummaryType' to '{0}'" -f $Summary)
		$managedProperty.SummaryType = $summaryTypes[$Summary]
		$appliedChange = $true
	}	

	# Create, update or remove full-text index mapping as necessary
	$ftiMapping = Get-FASTSearchMetadataFullTextIndexMapping -FullTextIndex $fti -ManagedProperty $managedProperty
	if(($ftiMapping -eq $null) -and ($Level -gt 0)) {
		Write-Verbose ("There is no existing full-text index mapping. Creating one with importance level {0}." -f $Level)
		New-FASTSearchMetadataFullTextIndexMapping -FullTextIndex $fti -ManagedProperty $managedProperty -Level $Level | Out-Null
		$appliedChange = $true		
	} elseif(($ftiMapping -ne $null) -and ($Level -eq 0)) {
		Write-Verbose ("Removing existing full-text index mapping, i.e. level was removed or set to 0." -f $Level)
		Remove-FASTSearchMetadataFullTextIndexMapping -Mapping $ftiMapping
		$appliedChange = $true
	} elseif(($ftiMapping -ne $null) -and $ftiMapping.ImportanceLevel -ne $Level) {
		Write-Verbose ("Updating the existing importance level from '{0}' to '{1}'" -f $ftiMapping.ImportanceLevel, $Level)
		Set-FASTSearchMetadataFullTextIndexMapping -Mapping $ftiMapping -Level $Level | Out-Null
		$appliedChange = $true		
	}
	
	# Sum up info for the user. This could have already been printed before FTI mappings, but make more sense here.
	if($appliedChange) {
		Write-Verbose "Update in progress..."
		$managedProperty.Update()
	} else {
		Write-Verbose "No optional settings were updated"
	}
	
	# If summary type was changed to dynamic, make sure there's a fallback
	if($Summary -eq "dynamic") {		
		if($managedProperty.GetResultFallBack() -eq $null) {
			Write-Verbose "Setting result fallback property since summary type was changed to dynamic"
			$managedProperty.SetResultFallBack($managedProperty)
		}
	}	
}

function RemoveManagedProperty([String]$Name) {
	Write-Host ("Removing managed property '{0}'" -f $Name)
		
	$managedProperty = Get-FASTSearchMetadataManagedProperty -Name $Name
	if($managedProperty -eq $null) {
		Write-Verbose ("The managed property '{0}' does not exist" -f $Name)
	} else {
		Remove-FASTSearchMetadataManagedProperty -ManagedProperty $managedProperty -Force
		Write-Verbose "Successfully removed managed property"
	}
}

function DeployCrawledPropertyCategory([String]$Name) {
	Write-Host ("Deploying crawled property category '{0}'" -f $Name)
	
	$category = Get-FASTSearchMetadataCategory -Name $Name
	if($category -ne $null) { 
		Write-Verbose ("Crawled property category '{0}' already exists" -f $Name)
	} else {
		$propertySet = [Guid]::NewGuid()
		$category = New-FASTSearchMetadataCategory -name $Name -Propset $propertySet
		Write-Verbose ("Successfully created crawled property category '{0}'" -f $Name)
	}
}

function DeployCrawledProperty([String]$Name, [String]$Type, [String]$Category) {
	Write-Host ("Deploying crawled property '{0}'" -f $Name)

	# Verification: The category has to exist
	$crawledPropertyCategory = Get-FASTSearchMetadataCategory -Name $Category
	if($crawledPropertyCategory -eq $null) { 
		Write-Error ("The category '{0}' does not exist, hence the crawled property could not be created." -f $Category) -ErrorAction Stop
	}
	
	# Each crawled property needs to be in a category, identified by a property set.
	# Surprisingly, each category may have several property sets. We chose the set
	# with the most crawled properties already mapped to it. May be problematic, but works
	# just fine so far. Also store this data in cache, since calculation is expensive.
	if($propsetCache.ContainsKey($crawledPropertyCategory)) {
		$propertySet = $propsetCache[$crawledPropertyCategory]
	} else {
		$topSoFar = 0
		$propertySet = $null
		foreach($guid in $crawledPropertyCategory.GetPropsetMappings()) {
			$count = (Get-FASTSearchMetadataCrawledProperty | Where-Object { $_.Propset -eq $guid } | Measure-Object).Count
			if($count -ge $topSoFar) {
				$topSoFar = $count
				$propertySet = $guid
			}
		}

		# Save in cache
		$propsetCache[$crawledPropertyCategory] = $propertySet
	}
	
	# Create or get the crawled property
	$crawledProperty = Get-FASTSearchMetadataCrawledProperty -Name $Name -ErrorAction SilentlyContinue | Where-Object { $_.CategoryName -eq $Category }
	if($crawledProperty -eq $null) {
		# Verification: The type must be one of those in $cpTypes
		if(!$cpTypes.ContainsKey($Type)) {
			Write-Error ("The type '{0}' used in the definition of crawled property '{1}' is incorrect. The type needs to be one of '{2}'." -f $Type, $Name, [String]::Join(", ", $cpTypes.keys)) -ErrorAction Stop
		}
		
		New-FASTSearchMetadataCrawledProperty -Name $Name -VariantType $cpTypes[$Type] -Propset $PropertySet | Out-Null
		Write-Verbose ("Successfully created crawled property '{0}' in category '{1}'" -f $Name, $Category)
		
	} else {
		Write-Verbose ("Crawled property '{0}' already exists in category '{1}'" -f $Name, $Category)
	}
}

function DeployMappings([String]$ManagedPropertyName, [Object[]]$Mappings) {
	Write-Host ("Deploying mappings on managed property '{0}'" -f $ManagedPropertyName)
	
	$managedProperty = Get-FASTSearchMetadataManagedProperty -Name $ManagedPropertyName
	if($managedProperty -eq $null) {
		Write-Verbose ("The managed property '{0}' does not exist" -f $ManagedPropertyName) -ErrorAction Stop
	}
	
	# Create mapping against all listed crawled properties
	$Mappings | ForEach-Object {
		DeployMapping $ManagedPropertyName $_.name $_.category
	}

	# Remove old stale mappings
	$managedProperty.GetCrawledPropertyMappings() | ForEach-Object {
		$existingIsAlsoInXml = $false
		$existingMapping = $_
		$Mappings | ForEach-Object {
			if(($existingMapping.Name -eq $_.name) -and ($existingMapping.CategoryName -eq $_.category)) {
				$existingIsAlsoInXml = $true
			}
		}

		if($existingIsAlsoInXml -eq $false) {
			RemoveMapping $ManagedPropertyName $existingMapping.Name $existingMapping.CategoryName
		}
	}
}

function DeployMapping([String]$ManagedPropertyName, [String]$CrawledPropertyName, [String]$Category) {
	Write-Host ("Mapping '{0}':'{1}' to '{2}'" -f $Category, $CrawledPropertyName, $ManagedPropertyName)

	$crawledProperty = Get-FASTSearchMetadataCrawledProperty -Name $CrawledPropertyName -ErrorAction SilentlyContinue | Where-Object { $_.CategoryName -eq $Category }
	if($crawledProperty -eq $null) {
		Write-Error ("The crawled property '{0}' in category '{1}' does not exist" -f $CrawledPropertyName, $Category) -ErrorAction Stop
	}
	if(($crawledProperty | Measure-Object).Count -gt 1) {
		Write-Error ("There are '{0}' crawled properties called '{1}' in category '{2}'. Impossible to know which one to use." -f ($crawledProperty | Measure-Object).Count, $CrawledPropertyName, $Category) -ErrorAction Stop
	}
	
	if($crawledProperty.GetMappedManagedProperties() | Where-Object { $_.Name -eq $ManagedPropertyName }) {
		Write-Verbose "The properties are already mapped"
	} else {
		# Get the managed property to map against
		$managedProperty = Get-FASTSearchMetadataManagedProperty -Name $ManagedPropertyName
		if($managedProperty -eq $null) {
			Write-Verbose ("The managed property '{0}' does not exist" -f $ManagedPropertyName) -ErrorAction Stop
		}
	
		New-FASTSearchMetadataCrawledPropertyMapping -ManagedProperty $managedProperty -CrawledProperty $crawledProperty
		Write-Verbose "Successfully mapped properties"
	}
}

function RemoveMapping([String]$ManagedPropertyName, [String]$CrawledPropertyName, [String]$Category) {
	Write-Host ("Removing mapping from '{0}':'{1}' to '{2}'" -f $Category, $CrawledPropertyName, $ManagedPropertyName)
		
	$managedProperty = Get-FASTSearchMetadataManagedProperty -Name $ManagedPropertyName
	if($managedProperty -eq $null) {
		Write-Verbose ("The managed property '{0}' does not exist" -f $ManagedPropertyName) -ErrorAction Stop
	}
	
	$crawledProperty = Get-FASTSearchMetadataCrawledProperty -Name $CrawledPropertyName -ErrorAction SilentlyContinue | Where-Object { $_.CategoryName -eq $Category }
	if($crawledProperty -eq $null) {
		Write-Verbose ("The crawled property '{0}' does not exist" -f $CrawledPropertyName) -ErrorAction Stop
	}	
	if(($crawledProperty | Measure-Object).Count -gt 1) {
		Write-Error ("There are '{0}' crawled properties called '{1}' in category '{2}'. Impossible to know which one to use." -f ($crawledProperty | Measure-Object).Count, $CrawledPropertyName, $Category) -ErrorAction Stop
	}
	
	if(($crawledProperty.GetMappedManagedProperties() | Where-Object { $_.Name -eq $ManagedPropertyName }) -eq $null) {
		Write-Verbose "There is no mapping to remove"
	}

	Remove-FASTSearchMetadataCrawledPropertyMapping -ManagedProperty $managedProperty -CrawledProperty $crawledProperty -Force
	Write-Verbose "Successfully removed mapping"
}

# SCRIPT ENTRY POINT

# If parameter switch -GenerateExampleSchema is used, print example schema and exit
if($GenerateExampleSchema) {
	Write-Output @"
<FastIndexSchema>

	<!-- Create a new full-text index in which properties are mapped -->
	<!-- All attributes are optional, omit 'name' to use the default fti -->
	<FullTextIndex name="myFti" desc="My own full-text index" stemming="false">

		<!-- Create a new managed property with the bare minimum of settings -->
		<ManagedProperty name="mp1" type="text" description="Simple managed property">
			<!-- Create a new crawled property and map to the 'mp1' -->
			<CrawledProperty name="cp1" type="text" category="test" />
		</ManagedProperty>	

		<!-- Create a new managed property using all possible customizations -->
		<ManagedProperty name="mp2" type="text" description="Advanced managed property" sort="latent" query="true" refine="true" stemming="true" merge="true" summary="dynamic" level="7">
			<CrawledProperty name="cp1" type="text" category="test" />
			<!-- Map an already existing crawled property (no need to specify type) -->
			<CrawledProperty name="ows_Email" category="SharePoint" />
		</ManagedProperty>	
	
	</FullTextIndex>
	
</FastIndexSchema>
"@
	break
}

# Import required libraries
if((Get-PSSnapin Microsoft.FASTSearch.PowerShell -ErrorAction SilentlyContinue) -eq $null) {
    Add-PSSnapin Microsoft.FASTSearch.PowerShell -ErrorAction Stop
}

# Read the schema file, abort if XML is invalid
[Xml]$schema = Get-Content $SchemaFile
if($schema -eq $null) {
	break
}

# Some basic sanity checks before we start
if($schema.FastIndexSchema -eq $null) {
	Write-Error "The schema file does not contain the root tag 'FastIndexSchema'" -ErrorAction Stop
}
$schema | Select-Xml -XPath "//ManagedProperty" | ForEach-Object {
	if(($null, "", $_.Node.LocalName) -contains $_.Node.name) {
		Write-Error "Attribute 'name' is required for managed properties" -ErrorAction Stop
	}
	if(($null, "", $_.Node.LocalName) -contains $_.Node.type) {
		Write-Error "Attribute 'type' is required for managed properties" -ErrorAction Stop
	}
}
$schema | Select-Xml -XPath "//CrawledProperty" | ForEach-Object {
	if( ($null, "", $_.Node.LocalName) -contains $_.Node.name) {
		Write-Error "Attribute 'name' is required for crawled properties" -ErrorAction Stop
	}
	if( ($null, "", $_.Node.LocalName) -contains $_.Node.category) {
		Write-Error "Attribute 'category' is required for crawled properties" -ErrorAction Stop
	}
}

# ACTUAL PROCESSING BEGINS

# Deployment (normal) mode
if($Undeploy -eq $false) {

	# Loop over full-text indexes
	$schema.FastIndexSchema.ChildNodes | Where-Object { $_.LocalName -eq "FullTextIndex" } | ForEach-Object {

		# Fetch full-text index settings
		$ftiSettings = @{}
		if($_.HasAttribute("name")) {
			$ftiSettings.Add("name", $_.name)
		} else {
			# Pass empty string to deal with default fti
			$ftiSettings.Add("name", "")
		}
		if($_.HasAttribute("description")) {
			$ftiSettings.Add("description", $_.description)
		}
		if($_.HasAttribute("stemming")) {
			$ftiSettings.Add("stemming", $booleans[$_.stemming])
		}

		# Create/update the full-text index
		$fti = DeployFullTextIndex @ftiSettings

		# Loop over managed properties
		$_.ChildNodes | Where-Object { $_.LocalName -eq "ManagedProperty" } | ForEach-Object {

			# Fetch managed property settings (attributes 'ManagedPropertyName' and 'Type' are required)
			$mpSettings = @{ name = $_.name; type = $_.type; fti = $fti }
			if($_.HasAttribute("description")) {
				$mpSettings.Add("description", $_.description)
			}
			if($_.HasAttribute("sort")) {
				$mpSettings.Add("sort", $_.sort)
			}
			if($_.HasAttribute("query")) {
				$mpSettings.Add("query", $booleans[$_.query])
			}
			if($_.HasAttribute("refine")) {
				$mpSettings.Add("refine", $booleans[$_.refine])
			}
			if($_.HasAttribute("stemming")) {
				$mpSettings.Add("stemming", $booleans[$_.stemming])
			}
			if($_.HasAttribute("merge")) {
				$mpSettings.Add("merge", $booleans[$_.merge])
			}		
			if($_.HasAttribute("summary")) {
				$mpSettings.Add("summary", $_.summary)
			}
			if($_.HasAttribute("level")) {
				$mpSettings.Add("level", $_.level)
			}		
			
			# Create/update the managed property
			DeployManagedProperty @mpSettings

			# Store managed property's name in order to do mapping further down
			$mpName = $_.name
					
			# Loop over crawled properties associated to the managed property
			$_.ChildNodes | Where-Object { $_.LocalName -eq "CrawledProperty" } | ForEach-Object {
				
				# Create the category (if not already present)
				DeployCrawledPropertyCategory $_.category
			
				# Fetch crawled property settings (attributes 'Name' and 'Category' are required, 'Type' only when creating a new crawled property)
				$cpSettings = @{ name = $_.name; category = $_.category }
				if($_.HasAttribute("type")) {
					$cpSettings.Add("type", $_.type)
				}		
			
				# Create/update the crawled property
				DeployCrawledProperty @cpSettings
			}
			
			$activeMappings = $_.ChildNodes | Where-Object { $_.LocalName -eq "CrawledProperty" } |
											  Select-Object @{Name="Name"; Expression = {$_.name}},
															@{Name="Category"; Expression = {$_.category}}
			DeployMappings $mpName $activeMappings
		}

	}
}
# Undeployment mode
else {
	# Issue warning that this is real stuff -- index content is about to get removed
	Write-Warning "Continuing with this command may remove content from your index." -WarningAction Inquire

	# Loop over full-text indexes
	$schema.FastIndexSchema.ChildNodes | Where-Object { $_.LocalName -eq "FullTextIndex" } | ForEach-Object {

		# Loop over managed properties
		$crawledProperties = @()
		$_.ChildNodes | Where-Object { $_.LocalName -eq "ManagedProperty" } | ForEach-Object {
		
			# Delete the managed property (this will obviously remove its mappings to crawled properties)
			RemoveManagedProperty $_.name
			
			# Loop over crawled properties that were once associated to the managed property		
			$crawledProperties += $_.ChildNodes | Where-Object { $_.LocalName -eq "CrawledProperty" } 
		}
		
		# Delete the full-text index (but not if it's set to default!)
		if($_.HasAttribute("name")) {
			RemoveFullTextIndex $_.name
		}
	}

	Write-Host "It is impossible to safely remove crawled properties and categories."
	Write-Host "If you want to, remove the following properties and groups manually."
	$output = @{Label="Category"; Expression={$_.category}; width=20}, @{Label="Crawled property"; Expression={$_.name}}
	$crawledProperties | Select-Object -Unique Category, Name | Format-Table $output
}

# Finish off with a pretty line-break
Write-Host