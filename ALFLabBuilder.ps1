##############################################################
# Version: ALF Lab Builder 2.0.22   (should match VERSION.txt - if this file was replaced on its own, check it is from the same release)
# ALFLabBuilder.ps1   -   1. ALF Lab Builder - Planning Console
# A simple window for keeping track of every value the Azure Local lab needs,
# and "rolling out" the lab scripts with those values filled in.
#
# HOW IT WORKS
#   - LabValues.json holds every value (name, description, example, rules).
#   - The lab scripts contain placeholders like {{HostVMName}}.
#   - "Roll out scripts" copies the scripts to the rollout folder and replaces
#     every {{placeholder}} with its value. The originals are never changed.
#   - Copy the rolled-out scripts to where they run (e.g. C:\ISO on the host).
#
# START IT: double-click Launch-ALFLabBuilder.cmd  (or run this file in Windows PowerShell)
#
# ADD A NEW VALUE: add an entry to LabValues.json, then put {{YourKey}} in the scripts.
#
# SHARING: "Export for sharing" writes a copy of your values with private ones (tenant ID,
#          subscription ID - anything marked "Private") and your folder paths removed.
##############################################################

param(
    [string]$ValuesFile = (Join-Path $PSScriptRoot "LabValues.json")
)

$ALFVersion = "2.0.22"   #increment on EVERY change (also LabValues.example.json, VERSION.txt, CHANGELOG.md)
. (Join-Path $PSScriptRoot 'ALFHostSizing.ps1')
. (Join-Path $PSScriptRoot 'ALFGuestSizing.ps1')
$script:HostSkus = @()
$script:HostSkuContext = ''

#Section colours: each numbered section belongs to a phase, which sets its header colour
#   Lab     (blue)   - building the lab platform: Azure, the host VM, the lab network, the admin station
#   Cluster (purple) - building the Azure Local cluster: cluster, Active Directory, nodes, portal wizard
$SectionPhase = @{ "1" = "Lab"; "2" = "Lab"; "3" = "Lab"; "4" = "Cluster"; "5" = "Cluster"; "6" = "Cluster"; "7" = "Cluster"; "8" = "Lab" }

#WPF needs a single-threaded (STA) PowerShell - restart in one if needed
if ([Threading.Thread]::CurrentThread.ApartmentState -ne "STA") {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`" -ValuesFile `"$ValuesFile`""
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

#One row in the table. INotifyPropertyChanged makes edits show up everywhere straight away.
if (-not ("LabValue" -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
public class LabValue : INotifyPropertyChanged {
    private string _value;
    private string _status;
    public System.Collections.ObjectModel.ObservableCollection<string> Choices { get; set; }
    public string Key { get; set; }
    public string Group { get; set; }
    public string Label { get; set; }
    public string Description { get; set; }
    public string Example { get; set; }
    public string Pattern { get; set; }
    public string Hint { get; set; }
    public string UsedIn { get; set; }
    public string DifferentFrom { get; set; }
    public string Type { get; set; }
    public string Command { get; set; }
    public string IdentifierTemplate { get; set; }
    public bool Private { get; set; }
    public string Phase { get; set; }
    public string Token { get { return Type == "reminder" ? "(reminder - not used in scripts)" : Type == "info" ? "(built-in - not used in scripts)" : Type == "portal" ? "(Azure portal wizard)" : Type == "command" ? "(double-click to create the file)" : Type == "cli" ? "(Azure CLI - double-click to copy)" : "{{" + Key + "}}"; } }
    public string Value  { get { return _value; }  set { _value = value;  Notify("Value"); } }
    public string Status { get { return _status; } set { _status = value; Notify("Status"); } }
    public event PropertyChangedEventHandler PropertyChanged;
    private void Notify(string name) {
        PropertyChangedEventHandler h = PropertyChanged;
        if (h != null) h(this, new PropertyChangedEventArgs(name));
    }
}
'@
}


#========== WINDOW LAYOUT ==========
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="1. ALF Lab Builder - Planning Console" Height="1030" Width="1425"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="15">
  <DockPanel Margin="12">

    <!-- Title -->
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <StackPanel Orientation="Horizontal">
        <TextBlock Name="txtTitle" FontSize="22" FontWeight="SemiBold" Foreground="#0B5394" Text="1. ALF Lab Builder - Planning Console"/>
        <Border Background="#0B5394" CornerRadius="4" Padding="8,2" Margin="12,4,0,4" VerticalAlignment="Center">
          <TextBlock Name="txtVersion" Foreground="White" FontWeight="SemiBold" Text="v"/>
        </Border>
      </StackPanel>
      <TextBlock Name="txtFile" Foreground="Gray"/>
      <WrapPanel Margin="0,10,0,0">
        <TextBlock Text="Cluster identifier:" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,8,0"/>
        <TextBox Name="txtIdentifier" Width="75" MaxLength="4" FontFamily="Consolas" FontSize="18"
                 ToolTip="Choose exactly four digits. A new identifier regenerates all numbered lab names from their naming templates."/>
        <Button Name="btnApplyIdentifier" Content="Apply identifier" Padding="12,4" Margin="8,0,0,0"
                FontWeight="SemiBold" ToolTip="Update all eleven numbered lab names and command previews. Save values and roll out scripts afterward."/>
        <TextBlock Name="txtIdentifierStatus" VerticalAlignment="Center" Margin="10,0,0,0"/>
      </WrapPanel>
      <TextBlock Text="Choose four digits, then Apply identifier. Save values and roll out scripts afterward. Existing Azure resources are not renamed."
                 Foreground="Gray" TextWrapping="Wrap" Margin="0,4,0,0"/>
      <Border Background="#EAF3FB" CornerRadius="4" Padding="10,6" Margin="0,8,0,0">
        <TextBlock Name="txtSizingSummary" TextWrapping="Wrap" Text="Plan the SuperHost and guest CPU/RAM allocations in section 2."/>
      </Border>
    </StackPanel>

    <!-- Bottom: folders, buttons, log -->
    <Grid DockPanel.Dock="Bottom" Margin="0,10,0,0">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="170"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="160"/><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/>
      </Grid.ColumnDefinitions>

      <TextBlock Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Text="Script templates:"/>
      <TextBox   Grid.Row="0" Grid.Column="1" Name="txtTemplates" Margin="0,2"/>
      <Button    Grid.Row="0" Grid.Column="2" Name="btnBrowseTemplates" Content="Browse..." Margin="6,2,0,2"/>

      <TextBlock Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Text="Roll out to:"/>
      <TextBox   Grid.Row="1" Grid.Column="1" Name="txtRollout" Margin="0,2"/>
      <Button    Grid.Row="1" Grid.Column="2" Name="btnBrowseRollout" Content="Browse..." Margin="6,2,0,2"/>

      <StackPanel Grid.Row="2" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,8,0,8">
        <Button Name="btnSave"    Content="Save values"        Width="140" Margin="0,0,8,0"/>
        <Button Name="btnReload"  Content="Reload"             Width="100"  Margin="0,0,8,0"/>
        <Button Name="btnCheck"   Content="Check values"       Width="140" Margin="0,0,8,0"/>
        <Button Name="btnRollout" Content="Roll out scripts"   Width="165" Margin="0,0,8,0" FontWeight="SemiBold"/>
        <Button Name="btnOpen"    Content="Open rollout folder" Width="175" Margin="0,0,8,0"/>
        <Button Name="btnShare"   Content="Export for sharing"  Width="175"/>
      </StackPanel>

      <StackPanel Grid.Row="3" Grid.ColumnSpan="3" Orientation="Horizontal" Margin="0,0,0,8">
        <TextBlock Text="Azure (opens a PowerShell window):" VerticalAlignment="Center" FontWeight="SemiBold" Foreground="#0B5394" Margin="0,0,10,0"/>
        <Button Name="btnAzRG"     Content="1. Create resource groups" Width="215" Margin="0,0,8,0"/>
        <Button Name="btnAzRoles"  Content="2. Assign roles on RG"     Width="195" Margin="0,0,8,0"/>
        <Button Name="btnAzPolicy" Content="3. Review Azure Policy"    Width="195" Margin="0,0,8,0"/>
        <Button Name="btnAzAll"    Content="All 3"                     Width="80"/>
      </StackPanel>

      <TextBox Grid.Row="4" Grid.ColumnSpan="3" Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="14"
               VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" Background="#F7F7F7"/>
    </Grid>

    <!-- Middle: values table + details -->
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/><ColumnDefinition Width="370"/>
      </Grid.ColumnDefinitions>

      <DataGrid Grid.Column="0" Name="grid" AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
                CanUserSortColumns="False" HeadersVisibility="Column" SelectionMode="Single" GridLinesVisibility="Horizontal"
                RowHeight="30">
        <DataGrid.GroupStyle>
          <GroupStyle>
            <GroupStyle.HeaderTemplate>
              <DataTemplate>
                <!-- Coloured band per section. The colour comes from the section's phase (set in $SectionPhase):
                     Lab = building the lab platform, Cluster = building the Azure Local cluster -->
                <Border Margin="0,12,0,2" Padding="10,5" CornerRadius="3">
                  <Border.Style>
                    <Style TargetType="Border">
                      <Setter Property="Background" Value="#0B5394"/>
                      <Style.Triggers>
                        <DataTrigger Binding="{Binding Items[0].Phase}" Value="Cluster">
                          <Setter Property="Background" Value="#5C2D91"/>
                        </DataTrigger>
                      </Style.Triggers>
                    </Style>
                  </Border.Style>
                  <DockPanel>
                    <TextBlock DockPanel.Dock="Right" VerticalAlignment="Center" Margin="12,0,0,0" FontSize="13" Foreground="#E6FFFFFF">
                      <TextBlock.Style>
                        <Style TargetType="TextBlock">
                          <Setter Property="Text" Value="Building the lab"/>
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding Items[0].Phase}" Value="Cluster">
                              <Setter Property="Text" Value="Building the cluster"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </TextBlock.Style>
                    </TextBlock>
                    <TextBlock Text="{Binding Name}" FontSize="19" FontWeight="SemiBold" Foreground="White" TextTrimming="CharacterEllipsis"/>
                  </DockPanel>
                </Border>
              </DataTemplate>
            </GroupStyle.HeaderTemplate>
          </GroupStyle>
        </DataGrid.GroupStyle>
        <DataGrid.Columns>
          <DataGridTextColumn Header="Name"  Binding="{Binding Label, Mode=OneWay}" IsReadOnly="True" Width="290"/>
          <DataGridTemplateColumn Header="Value" Width="*">
            <DataGridTemplateColumn.CellTemplate>
              <DataTemplate>
                <Grid>
                  <TextBlock Text="{Binding Value}" VerticalAlignment="Center">
                    <TextBlock.Style><Style TargetType="TextBlock"><Style.Triggers>
                      <DataTrigger Binding="{Binding Key}" Value="HostVMSize"><Setter Property="Visibility" Value="Collapsed"/></DataTrigger>
                    </Style.Triggers></Style></TextBlock.Style>
                  </TextBlock>
                  <DockPanel>
                    <DockPanel.Style><Style TargetType="DockPanel"><Setter Property="Visibility" Value="Collapsed"/><Style.Triggers>
                      <DataTrigger Binding="{Binding Key}" Value="HostVMSize"><Setter Property="Visibility" Value="Visible"/></DataTrigger>
                    </Style.Triggers></Style></DockPanel.Style>
                    <Button DockPanel.Dock="Right" Name="btnHostSizes" Content="Refresh Azure sizes" Padding="5,0" ToolTip="Requires Azure CLI sign-in. Reads available lab-compatible sizes in South Central US for this subscription."/>
                    <ComboBox Name="cmbHostSize" ItemsSource="{Binding Choices}" Text="{Binding Value, UpdateSourceTrigger=PropertyChanged}" IsEditable="True" IsTextSearchEnabled="True"/>
                  </DockPanel>
                </Grid>
              </DataTemplate>
            </DataGridTemplateColumn.CellTemplate>
            <DataGridTemplateColumn.CellEditingTemplate>
              <DataTemplate><TextBox Text="{Binding Value, UpdateSourceTrigger=PropertyChanged}"/></DataTemplate>
            </DataGridTemplateColumn.CellEditingTemplate>
          </DataGridTemplateColumn>
          <DataGridTextColumn Header="Status" Binding="{Binding Status, Mode=OneWay}" IsReadOnly="True" Width="130"/>
          <DataGridTextColumn Header="Placeholder in scripts" Binding="{Binding Token, Mode=OneWay}" IsReadOnly="True" Width="230"/>
        </DataGrid.Columns>
      </DataGrid>

      <Border Grid.Column="1" Margin="10,0,0,0" Padding="10" BorderBrush="#DDDDDD" BorderThickness="1" Background="#FBFBFB">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Name="dLabel" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap" Text="Select a value"/>
            <TextBlock Name="dDescription" TextWrapping="Wrap" Margin="0,8,0,0"/>
            <TextBlock Text="Example" FontWeight="SemiBold" Margin="0,12,0,0"/>
            <TextBlock Name="dExample" TextWrapping="Wrap" FontFamily="Consolas"/>
            <TextBlock Text="Rules" FontWeight="SemiBold" Margin="0,12,0,0"/>
            <TextBlock Name="dHint" TextWrapping="Wrap"/>
            <TextBlock Text="Used in" FontWeight="SemiBold" Margin="0,12,0,0"/>
            <TextBlock Name="dUsedIn" TextWrapping="Wrap" FontFamily="Consolas"/>
            <TextBlock Text="Placeholder" FontWeight="SemiBold" Margin="0,12,0,0"/>
            <TextBlock Name="dToken" TextWrapping="Wrap" FontFamily="Consolas"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes("//*[@Name]") | ForEach-Object { $ui[$_.Name] = $window.FindName($_.Name) }


#========== DATA ==========
$items = New-Object System.Collections.ObjectModel.ObservableCollection[LabValue]
$ui.grid.ItemsSource = $items
$view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($items)
$view.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription "Group"))

$script:LabData  = $null
$script:Snapshot = ""
$script:AppliedIdentifier = ""
$IdentifierTemplates = [ordered]@{
    HostResourceGroup = 'LABHOST{ClusterIdentifier}-rg'
    HostVMName = 'LABHOST{ClusterIdentifier}-vm'
    ClusterResourceGroup = 'LABCLUSTER{ClusterIdentifier}-rg'
    ClusterName = 'LABcluster{ClusterIdentifier}'
    OUPath = 'OU=LABcluster{ClusterIdentifier},DC=contosolab,DC=local'
    LCMAccountName = 'LCMaccount{ClusterIdentifier}'
    NodeName1 = 'AzL{ClusterIdentifier}Node1'
    NodeName2 = 'AzL{ClusterIdentifier}Node2'
    KeyVaultName = 'LABcluster{ClusterIdentifier}-hcikv'
    CustomLocationName = 'LABcluster{ClusterIdentifier}-cl'
    WitnessStorageAccount = 'labcluster{ClusterIdentifier}sa'
}

function Get-BundledClusterIdentifier([string]$Version) {
    $v = [version]$Version
    $identifier = '{0}{1}{2:D2}' -f $v.Major, $v.Minor, $v.Build
    if ($identifier -cnotmatch '\A[0-9]{4}\z') { throw "Version $Version cannot form a four-digit cluster identifier." }
    return $identifier
}

function Get-ClusterNamingTemplate($Row, [string]$PreviousIdentifier) {
    if ($PreviousIdentifier -cmatch '\A[0-9]{4}\z') {
        $pattern = '(?<![0-9])' + [regex]::Escape($PreviousIdentifier) + '(?![0-9])'
        if ($Row.Value -match $pattern) {
            return ([regex]::new($pattern)).Replace($Row.Value, '{ClusterIdentifier}', 1)
        }
    }
    if ($Row.Key -eq 'OUPath' -and $Row.Value -match '^OU=[^,]+,(.+)$') {
        return 'OU=LABcluster{ClusterIdentifier},' + $Matches[1]
    }
    if ($Row.IdentifierTemplate) { return $Row.IdentifierTemplate }
    return $IdentifierTemplates[$Row.Key]
}

function Get-ClusterIdentifierValues($Rows, [string]$Identifier) {
    if ($Identifier -cnotmatch '\A[0-9]{4}\z') { throw 'The cluster identifier must be exactly four ASCII digits.' }
    $values = [ordered]@{}
    foreach ($row in $Rows) {
        if ($IdentifierTemplates.Contains($row.Key)) {
            $template = if ($row.IdentifierTemplate) { $row.IdentifierTemplate } else { $IdentifierTemplates[$row.Key] }
            if (-not $template.Contains('{ClusterIdentifier}')) { throw "The naming template for $($row.Key) has no cluster identifier." }
            $values[$row.Key] = $template.Replace('{ClusterIdentifier}', $Identifier)
        }
    }
    return $values
}

function Set-ClusterIdentifier([switch]$Quiet, [switch]$Apply) {
    $identifier = $ui.txtIdentifier.Text
    $valid = $identifier -cmatch '\A[0-9]{4}\z'
    $ui.btnApplyIdentifier.IsEnabled = $valid -and $identifier -ne $script:AppliedIdentifier
    if (-not $valid) {
        $ui.txtIdentifierStatus.Text = 'Enter exactly four digits (0000-9999).'
        $ui.txtIdentifierStatus.Foreground = [Windows.Media.Brushes]::DarkRed
        if (-not $Quiet) { Write-Log 'Choose a valid four-digit cluster identifier before saving or generating commands.' }
        return $false
    }
    if ($identifier -ne $script:AppliedIdentifier -and -not $Apply) {
        $ui.txtIdentifierStatus.Text = "Not applied: $identifier. Click Apply identifier (current plan: $script:AppliedIdentifier)."
        $ui.txtIdentifierStatus.Foreground = [Windows.Media.Brushes]::DarkOrange
        if (-not $Quiet) { Write-Log 'Click Apply identifier before saving or generating commands for the new identifier.' }
        return $false
    }
    if ($identifier -eq $script:AppliedIdentifier) {
        $ui.txtIdentifierStatus.Text = "Applied: $identifier (bundle default: $(Get-BundledClusterIdentifier $ALFVersion))"
        $ui.txtIdentifierStatus.Foreground = [Windows.Media.Brushes]::DarkGreen
        return $true
    }
    if (-not $ui.grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)) { return $false }
    foreach ($i in $items) {
        if ($IdentifierTemplates.Contains($i.Key)) {
            $i.IdentifierTemplate = Get-ClusterNamingTemplate $i $script:AppliedIdentifier
        }
    }
    try { $values = Get-ClusterIdentifierValues $items $identifier }
    catch { Write-Log $_.Exception.Message; return $false }
    foreach ($i in $items) {
        if ($values.Contains($i.Key)) { $i.Value = $values[$i.Key]; $i.Example = $i.Value }
    }
    $script:AppliedIdentifier = $identifier
    Set-ClusterIdentifier -Quiet | Out-Null
    Update-Commands
    Update-Details
    Write-Log "Cluster identifier $identifier applied to $($values.Count) numbered lab names. Save the plan and roll out scripts for this cluster. Existing Azure resources are not renamed."
    return $true
}

function Write-Log([string]$Text) {
    $ui.txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Text`r`n")
    $ui.txtLog.ScrollToEnd()
}

function Get-CurrentJson {
    #Build the JSON from what's on screen
    $values = foreach ($i in $items) {
        [ordered]@{
            Key = $i.Key; Group = $i.Group; Label = $i.Label; Value = $i.Value
            Description = $i.Description; Example = $i.Example
            Pattern = $i.Pattern; Hint = $i.Hint; UsedIn = $i.UsedIn; DifferentFrom = $i.DifferentFrom; Type = $i.Type; Command = $i.Command; Private = $i.Private; IdentifierTemplate = $i.IdentifierTemplate
        }
    }
    $doc = [ordered]@{
        LabName  = $script:LabData.LabName
        Version = $ALFVersion
        ClusterIdentifier = $ui.txtIdentifier.Text
        Settings = [ordered]@{ TemplateFolder = $ui.txtTemplates.Text; RolloutFolder = $ui.txtRollout.Text }
        Values   = @($values)
    }
    $doc | ConvertTo-Json -Depth 6
}

function Get-ALFDomainNetbiosRow([string]$DomainFqdn) {
    $netbios = $DomainFqdn.Split('.')[0].ToUpperInvariant()
    if ($netbios.Length -gt 15) { $netbios = $netbios.Substring(0, 15) }
    [pscustomobject]@{
        Key = 'DomainNetbios'; Group = '5. Active Directory'; Label = 'Domain NetBIOS name'; Value = $netbios
        Description = 'The short (NetBIOS) name of the lab domain, used for sign-ins like CONTOSOLAB\Administrator. 07dc.DC-CreateForest.ps1 creates the domain with this name and the domain name in section 7 (Management - Domain). Usually the first part of the domain name in capitals. Choose it before 07dc runs - it cannot be changed afterwards.'
        Example = 'CONTOSOLAB'; Pattern = '^(?=.*[A-Za-z])[A-Za-z0-9-]{1,15}$'
        Hint = '1-15 letters, numbers or hyphens, with at least one letter, e.g. CONTOSOLAB'
        UsedIn = '07dc.DC-CreateForest.ps1, 08dc.DC-PostConfig.ps1, 08adm.Admin-Configure.ps1, 09dc.DC-PrepareADForAzureLocal.ps1, 12.Node-Configure.ps1'
        DifferentFrom = ''; Type = ''; Command = ''; Private = $false
    }
}

function Initialize-ALFDomainPlan($Plan) {
    #Plans from 2.0.21 and older have no NetBIOS row - add it at the top of section 5, taken from the domain name
    $domain = $Plan.Values | Where-Object Key -eq 'DomainFqdn' | Select-Object -First 1
    if (-not $domain) { return }
    if ($domain.Description -match 'typed in') {
        $domain.Description = 'Management tab. The Active Directory domain the nodes join. 07dc.DC-CreateForest.ps1 creates it, and the other lab scripts use it. Choose it before 07dc runs - the OU path in section 5 must end with this domain.'
        $domain.UsedIn = 'Azure portal deployment wizard, 07dc.DC-CreateForest.ps1, 08dc.DC-PostConfig.ps1, 08adm.Admin-Configure.ps1, 12.Node-Configure.ps1'
    }
    if ($Plan.Values | Where-Object Key -eq 'DomainNetbios') { return }
    $netbiosRow = Get-ALFDomainNetbiosRow ([string]$domain.Value)
    $rows = @()
    $added = $false
    foreach ($row in $Plan.Values) {
        if (-not $added -and $row.Key -eq 'OUPath') { $rows += $netbiosRow; $added = $true }
        $rows += $row
    }
    if (-not $added) { $rows += $netbiosRow }
    $Plan.Values = $rows
}

function Get-ALFDomainDN([string]$DomainFqdn) {
    return (($DomainFqdn.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
}

function Load-Values {
    if (-not (Test-Path $ValuesFile)) {
        [System.Windows.MessageBox]::Show("Can't find $ValuesFile", "1. ALF Lab Builder - Planning Console") | Out-Null
        return
    }
    $script:LabData = Get-Content $ValuesFile -Raw | ConvertFrom-Json
    Initialize-ALFHostSizingPlan $script:LabData
    Initialize-ALFGuestSizingPlan $script:LabData
    Initialize-ALFDomainPlan $script:LabData
    $identifier = [string]$script:LabData.ClusterIdentifier
    if (-not $identifier) {
        $cluster = $script:LabData.Values | Where-Object Key -eq 'ClusterName' | Select-Object -First 1
        $identifier = if ($cluster.Value -match '(?<![0-9])([0-9]{4})$') { $Matches[1] } else { Get-BundledClusterIdentifier $ALFVersion }
    }
    $items.Clear()
    foreach ($v in @($script:LabData.Values)) {
        $o = New-Object LabValue
        $o.Key = $v.Key; $o.Group = $v.Group; $o.Label = $v.Label; $o.Value = $v.Value
        $o.Description = $v.Description; $o.Example = $v.Example
        $o.Pattern = $v.Pattern; $o.Hint = $v.Hint; $o.UsedIn = $v.UsedIn; $o.DifferentFrom = $v.DifferentFrom; $o.Type = $v.Type; $o.Command = $v.Command; $o.Private = [bool]$v.Private
        $o.Choices = New-Object 'System.Collections.ObjectModel.ObservableCollection[string]'
        if ($o.Key -eq 'HostVMSize') {
            foreach ($choice in Get-ALFHostSizeChoices $o.Value) { $o.Choices.Add($choice) }
        }
        $o.IdentifierTemplate = $v.IdentifierTemplate
        if (-not $o.IdentifierTemplate -and $IdentifierTemplates.Contains($o.Key)) {
            #Older plans have no naming templates: retain their prefixes, suffixes and OU parent path.
            $o.IdentifierTemplate = Get-ClusterNamingTemplate $o $identifier
        }
        if ($IdentifierTemplates.Contains($o.Key)) { $o.Example = $o.Value }
        $o.Phase = "Lab"
        if ("$($v.Group)" -match '^(\d+)\.' -and $SectionPhase.ContainsKey($Matches[1])) { $o.Phase = $SectionPhase[$Matches[1]] }
        $items.Add($o)
    }

    #Folders - default to the folder this tool is in, and a "Rollout" folder beside it
    $tpl = $script:LabData.Settings.TemplateFolder
    $out = $script:LabData.Settings.RolloutFolder
    $ui.txtTemplates.Text = if ($tpl) { $tpl } else { $PSScriptRoot }
    $ui.txtRollout.Text   = if ($out) { $out } else { Join-Path $PSScriptRoot "Rollout" }
    $script:AppliedIdentifier = $identifier
    $ui.txtIdentifier.Text = $identifier
    Set-ClusterIdentifier -Quiet | Out-Null

    $ui.txtTitle.Text   = "1. ALF Lab Builder - Planning Console"
    $ui.txtVersion.Text = "Version $ALFVersion"
    if ($script:LabData.Version -and $script:LabData.Version -ne $ALFVersion) {
        Write-Log "Note: LabValues.json is from version $($script:LabData.Version); the Lab Builder is version $ALFVersion."
    }
    #Your time zone: empty means "use this PC's time zone"
    $tz = $items | Where-Object Key -eq "TimeZone"
    if ($tz -and [string]::IsNullOrWhiteSpace($tz.Value)) {
        $tz.Value = (Get-TimeZone).Id
        Write-Log "Your time zone set from this PC: $($tz.Value). Select Save to keep it, or type a different one."
    }
    $window.Title     = "1. ALF Lab Builder - Planning Console  (v$ALFVersion)"
    $ui.txtFile.Text  = "Values file: $ValuesFile"
    Update-Commands
    Test-Values -Quiet | Out-Null
    $script:Snapshot = Get-CurrentJson
    Write-Log "Loaded $($items.Count) values from $ValuesFile"
}

function Save-Values {
    if (-not (Set-ClusterIdentifier)) { return }
    #Saves ONLY the values, identifier, naming templates and folders. Names, descriptions, rules and order are re-read from
    #the file on disk, so an older open window can't overwrite an updated LabValues.json.
    $ui.grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
    $onScreen = @{}
    foreach ($i in $items) { if ($i.Type -notin @("reminder", "info", "command", "cli")) { $onScreen[$i.Key] = $i.Value } }

    $disk = Get-Content $ValuesFile -Raw | ConvertFrom-Json
    Initialize-ALFHostSizingPlan $disk
    Initialize-ALFGuestSizingPlan $disk
    Initialize-ALFDomainPlan $disk
    foreach ($v in @($disk.Values)) {
        if ($onScreen.ContainsKey($v.Key)) { $v.Value = $onScreen[$v.Key] }
        $row = $items | Where-Object Key -eq $v.Key | Select-Object -First 1
        if ($row -and $IdentifierTemplates.Contains($row.Key)) {
            $row.IdentifierTemplate = Get-ClusterNamingTemplate $row $script:AppliedIdentifier
            $v | Add-Member -NotePropertyName IdentifierTemplate -NotePropertyValue $row.IdentifierTemplate -Force
        }
    }
    $disk | Add-Member -NotePropertyName Version -NotePropertyValue $ALFVersion -Force
    $disk | Add-Member -NotePropertyName ClusterIdentifier -NotePropertyValue $script:AppliedIdentifier -Force
    if (-not $disk.Settings) {
        $disk | Add-Member -NotePropertyName Settings -NotePropertyValue ([pscustomobject]@{ TemplateFolder = ""; RolloutFolder = "" })
    }
    $disk.Settings.TemplateFolder = $ui.txtTemplates.Text
    $disk.Settings.RolloutFolder  = $ui.txtRollout.Text
    Set-Content -Path $ValuesFile -Value ($disk | ConvertTo-Json -Depth 6) -Encoding UTF8

    $script:Snapshot = Get-CurrentJson
    Write-Log "Saved $($items.Count) values to $ValuesFile"
    foreach ($sec in @($items | Where-Object { $_.Type -eq "secret" -and $_.Value })) {
        Write-Log "WARNING: '$($sec.Label)' is saved in plain text in this file. The security of the JSON file is your responsibility."
    }
}

function Refresh-HostSizes {
    $script:HostSkus = @()
    $script:HostSkuContext = ''
    try {
        $subscription = ($items | Where-Object Key -eq 'SubscriptionId').Value
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        $skus = @(Get-ALFHostSkus $subscription 'southcentralus')
        if (-not $skus.Count) { throw 'Azure returned no eligible sizes. Check region, subscription access and SKU restrictions.' }
        $script:HostSkus = $skus
        $script:HostSkuContext = "$subscription|southcentralus"
        $row = $items | Where-Object Key -eq 'HostVMSize'
        $selectedSize = $row.Value
        $row.Choices.Clear()
        foreach ($choice in Get-ALFHostSizeChoices $selectedSize $skus) { $row.Choices.Add($choice) }
        $row.Value = $selectedSize
        Write-Log "Loaded $($skus.Count) lab-compatible Azure sizes. Capacity and quota must still be checked before deployment."
    }
    catch { Write-Log "Host sizes not refreshed: $($_.Exception.Message)" }
    finally {
        $window.Cursor = $null
        Update-HostSizingStatus | Out-Null
        Update-LabSizingStatus | Out-Null
    }
}

function Update-HostSizingStatus {
    $size = $items | Where-Object Key -eq 'HostVMSize'
    $count = $items | Where-Object Key -eq 'HostAvailableVcpus'
    if (-not $size -or -not $count) { return $false }
    $subscription = ($items | Where-Object Key -eq 'SubscriptionId').Value
    $sku = if ($script:HostSkuContext -ceq "$subscription|southcentralus") { $script:HostSkus | Where-Object name -ceq $size.Value | Select-Object -First 1 } else { $null }
    try {
        $maximum = Test-ALFHostSizing $size.Value $count.Value $sku
        if ($size.Value -eq 'Custom (on-premises)') {
            $size.Status = 'On-premises'
            $count.Status = "$($count.Value) entered"
            $count.Hint = 'Manually entered logical processors available to this lab on an existing on-premises Windows/Hyper-V host. No Azure SKU maximum applies. Actual host capacity is checked before guest creation.'
            return $true
        }
        $warning = Get-ALFHostSizingWarning $size.Value $count.Value $sku
        $size.Status = if ($warning) { 'Check Azure' } else { 'Azure listed' }
        $count.Status = "$($count.Value) / $maximum max"
        $count.Hint = "Maximum $maximum. This is the requested available vCPU count, not a promise of Azure acceptance. Base VM price is unchanged; check quota separately. $warning"
        return $true
    }
    catch {
        $size.Status = 'Check sizing'
        $count.Status = 'Invalid sizing'
        $count.Hint = $_.Exception.Message
        return $false
    }
}

function Write-HostSizingWarning {
    $row = $items | Where-Object Key -eq 'HostVMSize'
    if ($row.Status -eq 'Check Azure') {
        Write-Log ('HOST SIZING WARNING: ' + ($items | Where-Object Key -eq 'HostAvailableVcpus').Hint)
    }
}

function Update-LabSizingStatus {
    $script:LabSizingWarning = ''
    $map = @{}
    foreach ($row in $items) { $map[$row.Key] = $row.Value }
    foreach ($field in Get-ALFGuestSizingFields) {
        $row = $items | Where-Object Key -eq $field.Key | Select-Object -First 1
        if ($row) {
            $number = 0
            $row.Status = if ($row.Value -match '^[1-9][0-9]*$' -and [int]::TryParse($row.Value, [ref]$number) -and $number -ge $field.Minimum) { 'OK' } else { 'Invalid sizing' }
            $row.Hint = $field.Detail
        }
    }
    $subscription = $map.SubscriptionId
    $sku = if ($script:HostSkuContext -ceq "$subscription|southcentralus") { $script:HostSkus | Where-Object name -ceq $map.HostVMSize | Select-Object -First 1 } else { $null }
    try {
        $budget = Test-ALFLabSizing $map $sku
        $script:LabSizingWarning = $budget.Warning
        $ui.txtSizingSummary.Text = "$($budget.GuestMemoryGB) / $($budget.AllocatableMemoryGB) GB guest RAM; $($budget.RemainingHostMemoryGB) GB remains for SuperHost ($($budget.HostReserveGB) GB reserved). $($budget.GuestVcpus) guest vCPUs / $($budget.HostVcpus) host vCPUs. $($budget.Warning)"
        $ui.txtSizingSummary.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($budget.Warning) { '#8A6100' } else { '#107C10' }))
        return $true
    }
    catch {
        $fieldKey = $_.Exception.Data['Field']
        $row = $items | Where-Object Key -eq $fieldKey | Select-Object -First 1
        if ($row) { $row.Status = 'Invalid sizing'; $row.Hint = $_.Exception.Message }
        $ui.txtSizingSummary.Text = 'INVALID LAB SIZING: ' + $_.Exception.Message
        $ui.txtSizingSummary.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString('#A4262C')
        return $false
    }
}

function Write-LabSizingWarning {
    if ($script:LabSizingWarning) { Write-Log ('LAB SIZING WARNING: ' + $script:LabSizingWarning) }
}

function Expand-LabTemplate([string]$Text) {
    #Replaces {{Key}} with its value; a missing value becomes <Key> so it's easy to spot
    $map = @{}
    foreach ($i in $items) { if ($i.Type -notin @("command", "cli", "reminder", "info")) { $map[$i.Key] = $i.Value } }
    return [regex]::Replace($Text, '\{\{([A-Za-z0-9_]+)\}\}', {
        param($m)
        $k = $m.Groups[1].Value
        if ($map.ContainsKey($k) -and $map[$k]) { $map[$k] } else { "<" + $k + ">" }
    })
}

function Get-CommandFilePath($Item) {
    return Join-Path $ui.txtRollout.Text $Item.Command
}

function Update-Commands {
    #Command rows point at a text template (e.g. AzurePrep-Commands.txt) in the templates folder.
    #Shows where the filled-in file will be created, and the filled-in text in the help panel.
    #One-line Azure CLI rows: the command, filled in, shown right in the table
    foreach ($i in $items | Where-Object Type -eq "cli") {
        if ($i.Key -eq 'CliCreateHostVM' -and ($items | Where-Object Key -eq 'HostVMSize').Value -eq 'Custom (on-premises)') {
            $i.Value = 'Not applicable - use your existing on-premises SuperHost; skip Azure host creation (script 00).'
            $i.Example = $i.Value
            $i.Status = 'Not applicable'
            continue
        }
        $i.Value   = Expand-LabTemplate $i.Command
        $i.Example = $i.Value
        if ($i.Key -eq 'CliCreateHostVM') {
            $i.Status = if ($i.Value -match "<[A-Za-z][A-Za-z0-9_]+>") { 'Fill values' } else { 'Copy' }
        }
    }
    foreach ($i in $items | Where-Object Type -eq "command") {
        $tplFile = Join-Path $ui.txtTemplates.Text $i.Command
        if (-not (Test-Path $tplFile)) {
            $i.Value = "Template not found: $($i.Command)"; $i.Example = ""; continue
        }
        $i.Example = Expand-LabTemplate (Get-Content $tplFile -Raw)
        $i.Value   = "Double-click to create and open $($i.Command)"
    }
}

function Test-Values([switch]$Quiet) {
    #Checks every value: empty, or doesn't match its rule. Returns the number of problems.
    $ui.grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
    $problems = 0
    if (-not (Set-ClusterIdentifier -Quiet:$Quiet)) { $problems++ }
    $byKey = @{}
    foreach ($i in $items) { $byKey[$i.Key] = $i }
    foreach ($i in $items) {
        #Reminder rows (passwords) are never recorded or checked
        if ($i.Type -eq "reminder") { $i.Status = "Reminder"; continue }
        if ($i.Type -eq "info")     { $i.Status = "Built-in"; continue }
        if ($i.Type -eq "cli")      {
            $i.Status = if ($i.Key -eq 'CliCreateHostVM' -and $byKey.HostVMSize.Value -eq 'Custom (on-premises)') { 'Not applicable' } elseif ($i.Value -match "<[A-Za-z][A-Za-z0-9_]+>") { "Fill values" } else { "Copy" }
            continue
        }
        if ($i.Type -eq "command")  {
            $i.Status = if (-not $i.Example) { "No template" } elseif ($i.Example -match "<[A-Za-z][A-Za-z0-9_]+>") { "Fill values" } else { "Ready" }
            continue
        }
        $other = if ($i.DifferentFrom) { $byKey[$i.DifferentFrom] } else { $null }
        if ($i.Type -eq "secret" -and [string]::IsNullOrWhiteSpace($i.Value)) { $i.Status = "Will ask"; continue }
        if ([string]::IsNullOrWhiteSpace($i.Value)) {
            $i.Status = "Missing"; $problems++
            if (-not $Quiet) { Write-Log "MISSING  $($i.Label)" }
        }
        elseif ($i.Pattern -and ($i.Value -notmatch $i.Pattern)) {
            $i.Status = "Check rule"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) = '$($i.Value)'  ->  $($i.Hint)" }
        }
        elseif ($i.Type -eq "secret" -and $i.Value -match "'") {
            $i.Status = "Check value"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) can't contain a single quote (')" }
        }
        elseif ($i.Type -ne "secret" -and $i.Value -match '["$`]') {
            $i.Status = "Check value"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) contains a character that breaks PowerShell strings:  `"  `$  ``" }
        }
        elseif ($other -and $other.Value -and ($i.Value -eq $other.Value)) {
            $i.Status = "Duplicate"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) can't be the same as $($other.Label) ('$($i.Value)')" }
        }
        elseif ($i.Key -eq "TimeZone" -and -not (Get-TimeZone -ListAvailable | Where-Object Id -eq $i.Value)) {
            #LEARN: Set-TimeZone only accepts an exact Windows ID from Get-TimeZone -ListAvailable
            $i.Status = "Check rule"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) '$($i.Value)' isn't a Windows time zone ID - run: Get-TimeZone -ListAvailable | Select-Object Id" }
        }
        elseif ($i.Key -eq "LCMAccountName" -and $i.Value -eq "admin") {
            $i.Status = "Check rule"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) can't be 'admin'" }
        }
        elseif ($i.Key -eq "OUPath" -and $byKey.DomainFqdn.Value -and $i.Value -notmatch (',' + [regex]::Escape((Get-ALFDomainDN $byKey.DomainFqdn.Value)) + '$')) {
            #LEARN: 09dc only creates the OU inside the lab domain, so the OU path must end with the domain's DC= parts
            $i.Status = "Check rule"; $problems++
            if (-not $Quiet) { Write-Log "INVALID  $($i.Label) '$($i.Value)' must end with $(Get-ALFDomainDN $byKey.DomainFqdn.Value) (the domain $($byKey.DomainFqdn.Value))" }
        }
        else { $i.Status = "OK" }
    }
    if (-not (Update-HostSizingStatus)) { $problems++; if (-not $Quiet) { Write-Log ('INVALID HOST SIZING: ' + ($items | Where-Object Key -eq 'HostAvailableVcpus').Hint) } }
    elseif (-not $Quiet) { Write-HostSizingWarning }
    if (-not (Update-LabSizingStatus)) { $problems++; if (-not $Quiet) { Write-Log $ui.txtSizingSummary.Text } }
    elseif (-not $Quiet) { Write-LabSizingWarning }
    $problems += Test-Network -Quiet:$Quiet
    if (-not $Quiet) {
        if ($problems) { Write-Log "$problems value(s) need attention." } else { Write-Log "All $($items.Count) values look good." }
    }
    return $problems
}

function ConvertTo-IPNumber([string]$Ip) {
    #192.168.44.51 -> one number, so addresses can be compared and counted
    $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    return ([int64]$b[0] * 16777216) + ([int64]$b[1] * 65536) + ([int64]$b[2] * 256) + [int64]$b[3]
}

function Test-Network([switch]$Quiet) {
    #Checks the IP values against each other: inside the lab network, no duplicates,
    #nothing inside the node, cluster resources or DHCP ranges, and each range is big enough.
    $problems = 0
    $subnet = $items | Where-Object Type -eq "subnet" | Select-Object -First 1
    if (-not $subnet -or $subnet.Status -ne "OK") { return 0 }

    $netIp, $bits = $subnet.Value.Split("/")
    $netStart = ConvertTo-IPNumber $netIp
    $netEnd   = $netStart + [math]::Pow(2, 32 - [int]$bits) - 1

    $ips = @($items | Where-Object { $_.Type -eq "ip" -and $_.Status -eq "OK" })
    function Set-Problem($Item, $Status, $Message) {
        $Item.Status = $Status
        if (-not $Quiet) { Write-Log "INVALID  $Message" }
    }

    #Inside the lab network (not the network or broadcast address)
    foreach ($i in $ips) {
        $n = ConvertTo-IPNumber $i.Value
        if ($n -le $netStart -or $n -ge $netEnd) {
            Set-Problem $i "Not in network" "$($i.Label) $($i.Value) is not a usable address in $($subnet.Value)"; $problems++
        }
    }

    #No two values share an address
    $ips | Group-Object Value | Where-Object Count -gt 1 | ForEach-Object {
        $labels = ($_.Group.Label) -join ", "
        foreach ($i in $_.Group) { Set-Problem $i "Duplicate" "$($_.Name) is used more than once: $labels" }
        $problems++
    }

    #Ranges: cluster resources, node IPs and DHCP
    $ranges = @(
        @{ Name = "cluster resources range"; Start = "InfraPoolStart"; End = "InfraPoolEnd"; Min = 6 }
        @{ Name = "node IP range";           Start = "NodeIPStart";    End = "NodeIPEnd";    Min = 2 }
        @{ Name = "DHCP range";              Start = "DhcpStart";      End = "DhcpEnd";      Min = 1 }
    )
    $byKey = @{}; foreach ($i in $items) { $byKey[$i.Key] = $i }
    $okRanges = @()
    foreach ($r in $ranges) {
        $s = $byKey[$r.Start]; $e = $byKey[$r.End]
        if (-not $s -or -not $e -or $s.Status -ne "OK" -or $e.Status -ne "OK") { continue }
        $sn = ConvertTo-IPNumber $s.Value; $en = ConvertTo-IPNumber $e.Value
        if ($en -lt $sn) {
            Set-Problem $e "Check rule" "The $($r.Name) ends ($($e.Value)) before it starts ($($s.Value))"; $problems++; continue
        }
        $size = $en - $sn + 1
        if ($size -lt $r.Min) {
            Set-Problem $e "Too small" "The $($r.Name) has $size address(es) - it needs at least $($r.Min)"; $problems++
        }
        $okRanges += @{ Name = $r.Name; Start = $sn; End = $en; Keys = @($r.Start, $r.End) }
    }

    #Nothing else may sit inside a range, and the ranges may not overlap
    foreach ($r in $okRanges) {
        foreach ($i in $ips) {
            if ($r.Keys -contains $i.Key -or $i.Status -ne "OK") { continue }
            $n = ConvertTo-IPNumber $i.Value
            if ($n -ge $r.Start -and $n -le $r.End) {
                Set-Problem $i "In a range" "$($i.Label) $($i.Value) is inside the $($r.Name)"; $problems++
            }
        }
    }
    for ($x = 0; $x -lt $okRanges.Count; $x++) {
        for ($y = $x + 1; $y -lt $okRanges.Count; $y++) {
            $ra = $okRanges[$x]; $rb = $okRanges[$y]
            if ($ra.Start -le $rb.End -and $rb.Start -le $ra.End) {
                Set-Problem $byKey[$rb.Keys[0]] "Overlap" "The $($rb.Name) overlaps the $($ra.Name)"; $problems++
            }
        }
    }

    #Show the size of each range when it's fine
    if (-not $Quiet) {
        foreach ($r in $okRanges) {
            Write-Log ("{0}: {1} addresses ({2} - {3})" -f $r.Name, ($r.End - $r.Start + 1), $byKey[$r.Keys[0]].Value, $byKey[$r.Keys[1]].Value)
        }
    }
    return $problems
}

function Invoke-Rollout {
    if (-not (Set-ClusterIdentifier)) { return }
    if (-not (Update-HostSizingStatus)) { Write-Log ('Rollout blocked: ' + ($items | Where-Object Key -eq 'HostAvailableVcpus').Hint); return }
    if (-not (Update-LabSizingStatus)) { Write-Log ('Rollout blocked: ' + $ui.txtSizingSummary.Text); return }
    #Secrets are rolled out inside '...' strings - a single quote would break the script, so never allow it
    $quotedSecret = @($items | Where-Object { $_.Type -eq "secret" -and $_.Value -match "'" })
    if ($quotedSecret.Count) {
        Write-Log ("Rollout blocked: {0} can't contain a single quote ('). Change it and roll out again." -f (($quotedSecret | ForEach-Object Label) -join ', '))
        return
    }
    if ((Test-Values) -gt 0) {
        $answer = [System.Windows.MessageBox]::Show("Some values are missing or invalid. Roll out anyway?`n`nPlaceholders without a value are left as {{...}} in the scripts.",
            "1. ALF Lab Builder - Planning Console", "YesNo", "Warning")
        if ($answer -ne "Yes") { Write-Log "Roll out cancelled."; return }
    }
    Save-Values

    $tpl = $ui.txtTemplates.Text
    $out = $ui.txtRollout.Text
    if (-not (Test-Path $tpl)) { Write-Log "Template folder not found: $tpl"; return }
    if ((Resolve-Path $tpl).Path -eq [IO.Path]::GetFullPath($out)) { Write-Log "The rollout folder can't be the same as the template folder."; return }
    New-Item -Path $out -ItemType Directory -Force | Out-Null

    #Lookup table: key -> value
    $map = @{}
    foreach ($i in $items) { if ($i.Type -notin @("reminder", "info", "command", "cli") -and -not [string]::IsNullOrWhiteSpace($i.Value)) { $map[$i.Key] = $i.Value } }

    #Scripts, command files and host/guest console launchers are rolled out; the Planning Console itself is not
    $files = Get-ChildItem -Path $tpl -File | Where-Object {
        ($_.Extension -in ".ps1", ".txt" -and $_.Name -ne "ALFLabBuilder.ps1") -or $_.Name -in @("Launch-ALFHostConsole.cmd", "Launch-ALFDCConsole.cmd", "Launch-ALFAdminConsole.cmd", "Launch-ALFNodeConsole.cmd")
    } | Sort-Object Name
    $pattern = '\{\{([A-Za-z0-9_]+)\}\}'
    $unknown = @{}
    Write-Log "Rolling out $($files.Count) scripts from $tpl to $out"

    foreach ($f in $files) {
        $text  = Get-Content -Path $f.FullName -Raw
        #Every lab file carries a version stamp in its header - flag any file from a different release
        if ($text -match '(?m)^(#|rem) Version: ALF Lab Builder (\S+)') {
            if ($Matches[2] -ne $ALFVersion) { Write-Log ("  WARNING: {0} is from version {1}; the Lab Builder is version {2}" -f $f.Name, $Matches[2], $ALFVersion) }
        }
        else { Write-Log ("  WARNING: {0} has no version stamp - it may be from an older release" -f $f.Name) }
        #Replace each {{Key}} with its value; leave unknown/empty ones as they are
        $new = [regex]::Replace($text, $pattern, {
            param($m)
            $k = $m.Groups[1].Value
            if ($map.ContainsKey($k)) { $map[$k] }
            else { $unknown[$k] = $true; $m.Value }
        })
        $count = @([regex]::Matches($text, $pattern) | Where-Object { $map.ContainsKey($_.Groups[1].Value) }).Count
        if ($f.Extension -eq ".cmd" -and $new -match '[^\x00-\x7F]') {
            Write-Log "Rollout failed: $($f.Name) contains non-ASCII text. CMD launchers must use ASCII."
            return
        }
        $encoding = if ($f.Extension -eq ".cmd") { "ASCII" } else { "UTF8" }
        Set-Content -Path (Join-Path $out $f.Name) -Value $new -Encoding $encoding -NoNewline
        if ($count) { Write-Log ("  {0,-38} {1} value(s) filled in" -f $f.Name, $count) }
        else        { Write-Log ("  {0,-38} copied (no placeholders)" -f $f.Name) }
    }

    if ($unknown.Count) {
        Write-Log "WARNING: these placeholders have no value and were left as-is: $(($unknown.Keys | ForEach-Object { '{{' + $_ + '}}' }) -join ', ')"
    }
    Write-Log "Roll out complete. Copy everything in $out to C:\ISO on the host, then start Launch-ALFHostConsole.cmd there."
}

function Select-Folder([string]$Start) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($Start -and (Test-Path $Start)) { $dlg.SelectedPath = $Start }
    if ($dlg.ShowDialog() -eq "OK") { return $dlg.SelectedPath }
    return $null
}


function Start-AzurePrep([string]$Step) {
    if (-not (Set-ClusterIdentifier)) { return }
    #Fills in Azure-Prep.ps1 with the current values and runs it in a new PowerShell window,
    #so sign-in prompts and long-running az commands don't freeze the Lab Builder.
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Log "The Azure CLI isn't installed on this PC. Install it:  winget install -e --id Microsoft.AzureCLI  - then restart the Lab Builder."
        return
    }
    Test-Values -Quiet | Out-Null
    $needed = @("TenantId", "SubscriptionId", "ArcRegion", "HostResourceGroup", "ClusterResourceGroup")
    $bad = @($items | Where-Object { $needed -contains $_.Key -and $_.Status -ne "OK" })
    if ($bad.Count) {
        Write-Log "Fix these values first: $(($bad.Label) -join ', ')"
        return
    }
    $tplFile = Join-Path $ui.txtTemplates.Text "Azure-Prep.ps1"
    if (-not (Test-Path $tplFile)) { Write-Log "Azure-Prep.ps1 not found in $($ui.txtTemplates.Text)"; return }

    Save-Values
    New-Item -Path $ui.txtRollout.Text -ItemType Directory -Force | Out-Null
    $out = Join-Path $ui.txtRollout.Text "Azure-Prep.ps1"
    Set-Content -Path $out -Value (Expand-LabTemplate (Get-Content $tplFile -Raw)) -Encoding UTF8
    Start-Process powershell.exe -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$out`" -Step $Step"
    $rg = ($items | Where-Object Key -eq "ClusterResourceGroup").Value
    Write-Log "Azure step '$Step' started in a new PowerShell window ($rg). Sign in there if asked."
}


function Export-Shareable {
    if (-not (Set-ClusterIdentifier)) { return }
    #Writes a copy of the values that's safe to share: private values (marked "Private": true,
    #e.g. tenant and subscription IDs) are emptied and the folder paths are removed.
    Save-Values
    $doc = Get-Content $ValuesFile -Raw | ConvertFrom-Json
    $cleared = @()
    foreach ($v in @($doc.Values)) {
        if ($v.Private) { $v.Value = ""; $cleared += $v.Label }
    }
    $doc.Settings.TemplateFolder = ""
    $doc.Settings.RolloutFolder  = ""
    New-Item -Path $ui.txtRollout.Text -ItemType Directory -Force | Out-Null
    $out = Join-Path $ui.txtRollout.Text "LabValues.shareable.json"
    Set-Content -Path $out -Value ($doc | ConvertTo-Json -Depth 6) -Encoding UTF8
    Write-Log "Saved a shareable copy: $out"
    Write-Log "  Emptied: $($cleared -join ', '); folder paths removed."
    Write-Log "  Check it before sharing - names like resource groups and cluster names are kept."
}


#========== EVENTS ==========
$ui.btnAzRG.Add_Click({     Start-AzurePrep "ResourceGroups" })
$ui.btnAzRoles.Add_Click({  Start-AzurePrep "Roles" })
$ui.btnAzPolicy.Add_Click({ Start-AzurePrep "Policy" })
$ui.btnAzAll.Add_Click({    Start-AzurePrep "All" })

$ui.txtIdentifier.Add_TextChanged({ Set-ClusterIdentifier -Quiet | Out-Null })
$ui.btnApplyIdentifier.Add_Click({
    if (Set-ClusterIdentifier -Apply) { Test-Values -Quiet | Out-Null }
})

#Keep the command rows up to date as values are edited
$window.AddHandler([System.Windows.Controls.Button]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.Button] -and $e.OriginalSource.Name -eq 'btnHostSizes') { Refresh-HostSizes; Update-Details; $e.Handled = $true }
})
$window.AddHandler([System.Windows.Controls.Primitives.Selector]::SelectionChangedEvent, [System.Windows.Controls.SelectionChangedEventHandler]{
    param($sender, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.ComboBox] -and $e.OriginalSource.Name -eq 'cmbHostSize') {
        $window.Dispatcher.BeginInvoke([action]{ Update-HostSizingStatus | Out-Null; Update-LabSizingStatus | Out-Null; Update-Commands; Update-Details }) | Out-Null
    }
})
$ui.grid.Add_CellEditEnding({ $window.Dispatcher.BeginInvoke([action]{ Update-HostSizingStatus | Out-Null; Update-LabSizingStatus | Out-Null; Update-Commands; Update-Details }) | Out-Null })

function Update-Details {
    $i = $ui.grid.SelectedItem
    if ($i) {
        $ui.dLabel.Text       = $i.Label
        $ui.dDescription.Text = $i.Description
        if ($i.Type -in "reminder", "secret") { $ui.dDescription.Text += "`r`n`r`nChoosing and remembering passwords is your responsibility." }
        if ($i.Type -eq "secret") { $ui.dDescription.Text += "`r`n`r`nWARNING: this password is saved in PLAIN TEXT in LabValues.json and in the rolled-out scripts. The security of those files is your responsibility." }
        $ui.dExample.Text     = $i.Example
        $ui.dHint.Text        = if ($i.Hint) { $i.Hint } else { "(none)" }
        $ui.dUsedIn.Text      = $i.UsedIn
        $ui.dToken.Text       = $i.Token
    }
}

$ui.grid.Add_SelectionChanged({ Update-Commands; Update-Details })

#Reminder rows (passwords) can't be edited - passwords are never typed into or saved by the Lab Builder
$script:SecretWarned = $false
$ui.grid.Add_BeginningEdit({
    param($sender, $e)
    if ($e.Row.Item.Type -eq "secret" -and -not $script:SecretWarned) {
        $script:SecretWarned = $true
        [System.Windows.MessageBox]::Show(
            "This password will be saved in PLAIN TEXT in LabValues.json and written into the rolled-out scripts.`n`n" +
            "The security of the JSON file (and the rolled-out scripts) is your responsibility.`n" +
            "Don't share them, and use 'Export for sharing' when you hand the values to someone else.`n`n" +
            "Leave it empty if you'd rather type the password on each node when the script asks.",
            "Planning Console - password stored in plain text", "OK", "Warning") | Out-Null
    }
    if ($e.Row.Item.Type -eq "cli") {
        if ($e.Row.Item.Key -eq 'CliCreateHostVM') {
            if (($items | Where-Object Key -eq 'HostVMSize').Value -eq 'Custom (on-premises)') {
                $e.Cancel = $true
                Write-Log 'Azure host creation is not applicable to Custom (on-premises). Use your existing SuperHost and skip script 00.'
                return
            }
            if (-not (Update-HostSizingStatus)) { $e.Cancel = $true; Write-Log ('Cannot copy host command: ' + ($items | Where-Object Key -eq 'HostAvailableVcpus').Hint); return }
            if (-not (Update-LabSizingStatus)) { $e.Cancel = $true; Write-Log ('Cannot copy host command: ' + $ui.txtSizingSummary.Text); return }
            Write-HostSizingWarning
            Write-LabSizingWarning
        }
        #Double-click (or F2) = copy the one-line command to the clipboard
        $e.Cancel = $true
        if (-not (Set-ClusterIdentifier)) { return }
        $ui.grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
        Update-Commands
        [System.Windows.Clipboard]::SetText($e.Row.Item.Value)
        Write-Log "Copied - paste into PowerShell (after az login) or Azure Cloud Shell:"
        Write-Log "  $($e.Row.Item.Value)"
        return
    }
    if ($e.Row.Item.Type -eq "command") {
        #Double-click (or F2) a command row = create the filled-in text file and open it
        $e.Cancel = $true
        if (-not (Set-ClusterIdentifier)) { return }
        $ui.grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
        Update-Commands
        $item = $e.Row.Item
        if (-not $item.Example) { Write-Log "Template $($item.Command) not found in $($ui.txtTemplates.Text)"; return }
        if ($item.Example -match "<[A-Za-z][A-Za-z0-9_]+>") { Write-Log "Some values are empty - look for <...> in the file." }
        New-Item -Path $ui.txtRollout.Text -ItemType Directory -Force | Out-Null
        $out = Get-CommandFilePath $item
        Set-Content -Path $out -Value $item.Example -Encoding UTF8
        Write-Log "Created $out - opening it in Notepad. Paste one step at a time into PowerShell or Cloud Shell."
        Start-Process notepad.exe $out
    }
    elseif ($e.Row.Item.Type -eq "info") {
        $e.Cancel = $true
        Write-Log "$($e.Row.Item.Label) is built in and can't be changed."
    }
    elseif ($e.Row.Item.Type -eq "reminder") {
        $e.Cancel = $true
        Write-Log "Passwords aren't recorded here. $($e.Row.Item.Label): you set it when prompted - $($e.Row.Item.Hint)."
        Write-Log "Choosing and remembering passwords is your responsibility."
    }
})

$ui.btnSave.Add_Click({ Save-Values; Test-Values -Quiet | Out-Null })
$ui.btnReload.Add_Click({ Load-Values })
$ui.btnCheck.Add_Click({ Test-Values | Out-Null })
$ui.btnRollout.Add_Click({ Invoke-Rollout })
$ui.btnShare.Add_Click({ Export-Shareable })
$ui.btnOpen.Add_Click({
    if (Test-Path $ui.txtRollout.Text) { Start-Process explorer.exe $ui.txtRollout.Text }
    else { Write-Log "Rollout folder doesn't exist yet - use 'Roll out scripts' first." }
})
$ui.btnBrowseTemplates.Add_Click({ $p = Select-Folder $ui.txtTemplates.Text; if ($p) { $ui.txtTemplates.Text = $p } })
$ui.btnBrowseRollout.Add_Click({   $p = Select-Folder $ui.txtRollout.Text;   if ($p) { $ui.txtRollout.Text = $p } })

#Ask to save on close if anything changed
$window.Add_Closing({
    param($sender, $e)
    $ui.grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true) | Out-Null
    if ((Get-CurrentJson) -ne $script:Snapshot) {
        $answer = [System.Windows.MessageBox]::Show("Save your changes before closing?", "1. ALF Lab Builder - Planning Console", "YesNoCancel", "Question")
        if ($answer -eq "Yes") {
            if (-not (Set-ClusterIdentifier)) { $e.Cancel = $true; return }
            Save-Values
        }
        if ($answer -eq "Cancel") { $e.Cancel = $true }
    }
})


#========== START ==========
#Opens at 1425 x 1030. On a smaller screen, shrink to fit the screen (minus the taskbar).
$work = [System.Windows.SystemParameters]::WorkArea
if ($window.Width  -gt $work.Width)  { $window.Width  = $work.Width }
if ($window.Height -gt $work.Height) { $window.Height = $work.Height }

Load-Values
$window.ShowDialog() | Out-Null
