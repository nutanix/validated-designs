$pathTemp = "${env:SystemRoot}" + "\Temp"
$pathDigiCertAssured = "$pathTemp" + "\DigiCertAssuredIDRootCA.crt"
$pathDigiCertSha2Assured = "$pathTemp" + "\DigiCertSHA2AssuredIDCodeSigningCA.crt"


Invoke-RestMethod -Uri https://dl.cacerts.digicert.com/DigiCertAssuredIDRootCA.crt -OutFile $pathDigiCertAssured
Invoke-RestMethod -Uri https://dl.cacerts.digicert.com/DigiCertSHA2AssuredIDCodeSigningCA.crt -OutFile $pathDigiCertSha2Assured
Import-Certificate -File $pathDigiCertAssured -CertStoreLocation 'Cert:\LocalMachine\Root'
Import-Certificate -File $pathDigiCertSha2Assured -CertStoreLocation 'Cert:\LocalMachine\Ca'
