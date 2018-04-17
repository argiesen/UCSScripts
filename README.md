# UCSScripts

### Get UCS version
```
$global:DefaultUcs | select Name,Ucs,Version,VirtualIpv4Address
```

### Get UCS servers (hardware)
```
Get-UcsServer | select ServerId,OperState,OperPower,Association,NumOfCpus,NumOfCores,TotalMemory,Model,Serial,MfgTime
```

### Get service profiles
```
Get-UcsServiceProfile | select Name,AssocState,SrcTemplName
```
