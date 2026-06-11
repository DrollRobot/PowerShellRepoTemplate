Function Get-GraphConsent {
    param(
        [switch] $RemoveAll
    )

    begin {

        $GraphCLTAppId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
        $ConsentStrings = [System.Collections.Generic.List[string]]::new()

        # colors
        $Blue = @{ ForegroundColor = 'Blue' }
    }

    process {

        # check if connected to graph
        try {
            $Context = Get-MgContext
        }
        catch {
            throw "Must be connected to Graph."
        }
        if (-not $Context) {
            throw "Must be connected to Graph."
        }

        ### check for scopes
        # build list of desired scopes
        $DesiredScopes = [System.Collections.Generic.List[string]]::new()
        $DesiredScopes.Add('Directory.Read.All')
        if ($RemoveAll) {
            # only needed for deleting grants
            $DesiredScopes.Add('DelegatedPermissionGrant.ReadWrite.All')
        }

        # build list of missing scopes
        $MissingScopes = [System.Collections.Generic.List[string]]::new()
        foreach ($Scope in $DesiredScopes) {
            if (-not $Context.Scopes -or ($Scope -notin $Context.Scopes)) {
                $MissingScopes.Add($Scope)
            }
        }

        # reconnect with missing scopes
        if (($MissingScopes | Measure-Object).Count -gt 0) {
            $ConnectParams = @{
                Scopes = $MissingScopes
                TenantId = $Context.TenantId
                NoWelcome = $true
            }
            Connect-MgGraph @ConnectParams
        }

        # get graph command line tools app
        $GraphCLTApp = Get-MgServicePrincipal -Filter "appId eq '$GraphCLTAppId'"

        # get all existing consent for gclt app
        $ExistingConsent = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($GraphCLTApp.Id)'"

        if ($null -eq $ExistingConsent) {
            Write-Host @Blue "`nNo current consent for Microsoft Graph Command Line Tools."
        }
        else {
            if ( $RemoveAll ) {
                foreach ( $Consent in $ExistingConsent ) {
                    Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $Consent.Id
                }
                Write-Host @Blue "`nRemoved all consent from Microsoft Graph Command Line Tools."
            }
            else {
                Write-Host @Blue "`nCurrent consent for Microsoft Graph Command Line Tools."
                # build consent strings list and output
                foreach ( $Consent in $ExistingConsent ) {
                    $Scopes = $Consent.Scope -split ' '
                    foreach ($Scope in $Scopes) {
                        $ConsentStrings.Add( $Scope )
                    }
                }
                $ConsentStrings = $ConsentStrings | Sort-Object
                foreach ($String in $ConsentStrings) { Write-Host $String }
            }
        }
    }
}
