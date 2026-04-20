import requests

# GitHub token for authentication
token = 'YOUR_GITHUB_TOKEN'

# Function to fetch release assets download counts for a repository
def fetch_release_asset_downloads(owner, repo):
    url = f'https://api.github.com/repos/{{owner}}/{{repo}}/releases'
    headers = {'Authorization': f'token {{token}}'}
    response = requests.get(url, headers=headers)
    releases = response.json()
    result = {}

    for release in releases:
        release_name = release['name']
        result[release_name] = []
        for asset in release['assets']:
            asset_name = asset['name']
            downloads = asset['download_count']
            result[release_name].append({'asset_name': asset_name, 'downloads': downloads})

    return result

# Fetch downloads for the specified repositories
repos = ['Aryeah86/Multi-Renamer', 'Aryeah86/SamplySync']

for repo in repos:
    owner, repo_name = repo.split('/')
    downloads = fetch_release_asset_downloads(owner, repo_name)
    print(f'\nDownload counts for repository: {repo_name}')
    for release, assets in downloads.items():
        print(f'Release: {release}')
        for asset in assets:
            print(f'  Asset: {asset['asset_name']} - Downloads: {asset['downloads']}')
