param (
)
git config user.email pipeline@tcetra.com; git config user.name "Pipeline";

$result = [PSCustomObject]@{
    ReleaseNotes = ""
    ReleaseVersion = ""
    Envs = ""
    IsDevTag = $true
}

try {
    $tag = $(git describe);
    $result.ReleaseVersion = $tag -replace "^v";

    if ($tag -NotMatch '^v\d{1,5}(-[0-9a-zA-Z-]+)?$') {
        throw "Tags must be of the format v{version}(-{lable})"
    }

    if ($tag -Match '^v\d{1,5}$') {

        $existsOnRelase = $false
        $branches = $(git branch -r --contains $tag)
        foreach ($branch in $branches) {
            if ($branch -Match "release") {
                $existsOnRelase = $true
            }
        }

        if (-not $existsOnRelase) {
            throw "Release Tags can only be associated with commits on release branch."
        }

        $result.IsDevTag = $false;
    }

    $tagDescription = $(git tag -l -n99 --no-column $tag | % { $_ -replace "^$tag\W*" });

    if ($result.IsDevTag) {
        if ($tagDescription -NotMatch '^[^|]*\|[^|]*(\|[^|]*)?$') {
          throw "Dev Tags Descriptions must match the format `"{{stackname}}|{{notes}}(|{{flag}})`""
        }

        $descParts = $tagDescription.Split('|');
        $result.Envs = $descParts[0].Trim();
        $result.ReleaseNotes = $descParts[1].Trim();
    }
    else {
        if ($tagDescription -NotMatch '^[^|]*(\|[^|]*)?$') {
            throw "Release Tags Descriptions must match the format `"{{notes}}(|{{flag}})`""
          }

          $descParts = $tagDescription.Split('|');
          $result.ReleaseNotes = $descParts[0].Trim();
    }

    Write-Host "##[debug]ReleaseVersion:$($result.ReleaseVersion)"
    Write-Host "##[debug]ReleaseNotes:$($result.ReleaseNotes)"
    Write-Host "##[debug]IsDevTag:$($result.IsDevTag)"
    Write-Host "##[debug]Envs:$($result.Envs)"
    Write-Host "##[debug]Flag:$($result.Flag)"

    echo "##vso[task.setvariable variable=ReleaseNotes;isOutput=true]$($result.ReleaseNotes)";
    echo "##vso[task.setvariable variable=ReleaseVersion;isOutput=true]$($result.ReleaseVersion)";
    echo "##vso[task.setvariable variable=Flag;isOutput=true]$($result.Flag)";
    echo "##vso[task.setvariable variable=Envs;isOutput=true]$($result.Envs)";
    echo "##vso[task.setvariable variable=IsDevTag;isOutput=true]$($result.IsDevTag)";
}
catch {
    git push --delete origin $tag
    throw;
}
