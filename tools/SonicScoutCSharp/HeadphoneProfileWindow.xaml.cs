using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace SonicScout;

public sealed record HeadphoneProfileOption(
    string Name,
    string Category,
    string FilterUrl,
    string Source,
    string? InlineFilterContent = null);

public sealed record TargetCurveOption(string Name, string FileName);

public partial class HeadphoneProfileWindow : Window
{
    private const string AutoEqSource = "AutoEq";
    private const string SquidLinkSource = "SquidLink";
    private const string ArtTuneSource = "ArtTuneDB";
    private const string AutoEqSourcesApiUrl = "https://api.github.com/repos/jaakkopasanen/AutoEq/contents/results";
    private const string AutoEqRawBaseUrl = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/";
    private static readonly HttpClient httpClient = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly TargetCurveOption[] TargetCurveOptions =
    [
        new("None", string.Empty),
        new("Battlefield 6 (V0/V1)", "BF6_Target_V1.txt"),
        new("Black Ops 6 (V6)", "BO6_Target_V6.txt"),
        new("PS5 Black Ops 6 (V6)", "PS5-BO6_Target_V6.txt"),
        new("Black Ops 7 (V0)", "BO7_Target_V0.txt"),
        new("Black Ops 7 (V3)", "BO7_Target_V3.txt"),
        new("Black Ops 7 (V4)", "BO7_Target_V4.txt"),
        new("Black Ops 7 (V5 / 16ch)", "BO7_Target_V5.txt"),
    ];
    private static readonly HashSet<string> HeadphoneCategoryTerms = new(StringComparer.OrdinalIgnoreCase)
    {
        "headphone", "headphones", "headset", "headsets", "overear"
    };
    private static readonly HashSet<string> IemCategoryTerms = new(StringComparer.OrdinalIgnoreCase)
    {
        "iem", "iems", "inear", "earbud", "earbuds", "earphone", "earphones"
    };

    private readonly List<HeadphoneProfileOption> allProfiles = new();
    private readonly List<HeadphoneProfileOption> visibleProfiles = new();

    public string ProfileName { get; private set; } = string.Empty;
    public string Category { get; private set; } = string.Empty;
    public string FilterContent { get; private set; } = string.Empty;
    public string? TargetCurveName { get; private set; }
    public string? TargetCurveContent { get; private set; }

    public HeadphoneProfileWindow()
    {
        InitializeComponent();
        httpClient.DefaultRequestHeaders.UserAgent.ParseAdd("SonicScout/1.0");
        foreach (TargetCurveOption option in TargetCurveOptions)
        {
            TargetCurveComboBox.Items.Add(option.Name);
        }
        TargetCurveComboBox.SelectedIndex = 0;
        Loaded += async (_, _) => await LoadCatalogAsync();
    }

    private async Task LoadCatalogAsync()
    {
        StatusText.Text = "Loading headset and IEM profile catalog...";
        try
        {
            allProfiles.Clear();
            await LoadArtTuneCatalogAsync();
            await LoadAutoEqCatalogAsync();
            await LoadSquidLinkCatalogAsync();
            ApplyFilter();
        }
        catch (HttpRequestException)
        {
            StatusText.Text = "Profile catalog is unavailable. Check your internet connection and press REFRESH.";
        }
        catch (TaskCanceledException)
        {
            StatusText.Text = "Profile catalog request timed out. Press REFRESH to try again.";
        }
        catch (JsonException)
        {
            StatusText.Text = "Profile catalog response was invalid. Press REFRESH to try again.";
        }
    }

    private async Task LoadArtTuneCatalogAsync()
    {
        string libraryPath = Environment.GetEnvironmentVariable("ART_TUNE_LIBRARY") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "ArtTuneDB-main", "library");
        if (!Directory.Exists(libraryPath))
        {
            return;
        }

        await Task.Run(() =>
        {
            foreach (string filterPath in Directory.EnumerateFiles(libraryPath, "*.txt", SearchOption.AllDirectories))
            {
                string normalizedPath = filterPath.Replace(Path.DirectorySeparatorChar, '/');
                if (!normalizedPath.Contains("/eq/", StringComparison.OrdinalIgnoreCase) ||
                    Path.GetFileName(filterPath).Equals("Flat_EQ.txt", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                string content = File.ReadAllText(filterPath);
                if (!ContainsValidEqData(content))
                {
                    continue;
                }

                string[] segments = normalizedPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length < 4)
                {
                    continue;
                }

                string game = segments[^3];
                string version = segments[^2];
                string profileName = Path.GetFileNameWithoutExtension(filterPath)
                    .Replace(" [2.0]", string.Empty, StringComparison.OrdinalIgnoreCase)
                    .Replace(" [1.0]", string.Empty, StringComparison.OrdinalIgnoreCase)
                    .Trim();
                string category = NormalizeCategory(string.Empty, profileName);
                string source = $"{ArtTuneSource}/{game}/{version}";
                if (allProfiles.Any(profile => profile.Name.Equals(profileName, StringComparison.OrdinalIgnoreCase) &&
                                               profile.Source.StartsWith(ArtTuneSource, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }

                allProfiles.Add(new HeadphoneProfileOption(profileName, category, string.Empty, source, content.Trim()));
            }
        });
    }

    private async Task LoadAutoEqCatalogAsync()
    {
        using JsonDocument sourceDocument = JsonDocument.Parse(await httpClient.GetStringAsync(AutoEqSourcesApiUrl));
        if (sourceDocument.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("AutoEq source response did not contain a valid array.");
        }

        HashSet<string> seenProfiles = new(StringComparer.OrdinalIgnoreCase);
        foreach (JsonElement source in sourceDocument.RootElement.EnumerateArray())
        {
            if (!source.TryGetProperty("type", out JsonElement sourceType) ||
                !string.Equals(sourceType.GetString(), "dir", StringComparison.OrdinalIgnoreCase) ||
                !source.TryGetProperty("name", out JsonElement sourceNameValue) ||
                sourceNameValue.ValueKind != JsonValueKind.String ||
                !source.TryGetProperty("sha", out JsonElement sourceShaValue) ||
                sourceShaValue.ValueKind != JsonValueKind.String)
            {
                continue;
            }

            string sourceName = sourceNameValue.GetString() ?? string.Empty;
            string sourceSha = sourceShaValue.GetString() ?? string.Empty;
            if (string.IsNullOrWhiteSpace(sourceName) || string.IsNullOrWhiteSpace(sourceSha))
            {
                continue;
            }

            string sourceTreeEndpoint = $"https://api.github.com/repos/jaakkopasanen/AutoEq/git/trees/{sourceSha}?recursive=1";
            using JsonDocument sourceTreeDocument = JsonDocument.Parse(await httpClient.GetStringAsync(sourceTreeEndpoint));
            if (!sourceTreeDocument.RootElement.TryGetProperty("tree", out JsonElement sourceTree) || sourceTree.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (JsonElement item in sourceTree.EnumerateArray())
            {
                if (!item.TryGetProperty("type", out JsonElement type) ||
                    !string.Equals(type.GetString(), "blob", StringComparison.OrdinalIgnoreCase) ||
                    !item.TryGetProperty("path", out JsonElement pathValue) ||
                    pathValue.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                string relativePath = pathValue.GetString() ?? string.Empty;
                if (!relativePath.EndsWith(" ParametricEQ.txt", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                string[] segments = relativePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length < 3)
                {
                    continue;
                }

                string profileName = segments[^2].Trim();
                string category = NormalizeCategory(segments[0], profileName);
                string dedupeKey = $"{sourceName}|{category}|{profileName}";
                if (!seenProfiles.Add(dedupeKey))
                {
                    continue;
                }

                if (allProfiles.Any(profile => profile.Source.StartsWith(ArtTuneSource, StringComparison.OrdinalIgnoreCase) &&
                                               profile.Name.Equals(profileName, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }

                string fullPath = $"results/{sourceName}/{relativePath}";
                string filterUrl = AutoEqRawBaseUrl + string.Join("/", fullPath.Split('/').Select(Uri.EscapeDataString));
                allProfiles.Add(new HeadphoneProfileOption(profileName, category, filterUrl, $"{AutoEqSource}/{sourceName}"));
            }
        }

        if (allProfiles.Count == 0)
        {
            // Fallback to the smaller known set if Git tree response changes or is unexpectedly empty.
            await LoadCategoryAsync("Headphones", "results/oratory1990/over-ear");
            await LoadCategoryAsync("IEMs", "results/oratory1990/in-ear");
        }
    }

    private async Task LoadCategoryAsync(string category, string path)
    {
        string endpoint = $"https://api.github.com/repos/jaakkopasanen/AutoEq/contents/{path}";
        using JsonDocument document = JsonDocument.Parse(await httpClient.GetStringAsync(endpoint));
        foreach (JsonElement item in document.RootElement.EnumerateArray())
        {
            if (!string.Equals(item.GetProperty("type").GetString(), "dir", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            string name = item.GetProperty("name").GetString() ?? string.Empty;
            string itemPath = item.GetProperty("path").GetString() ?? string.Empty;
            string filterPath = $"{itemPath}/{name} ParametricEQ.txt";
            string filterUrl = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/" +
                string.Join("/", filterPath.Split('/').Select(Uri.EscapeDataString));
            allProfiles.Add(new HeadphoneProfileOption(name, category, filterUrl, AutoEqSource));
        }
    }

    private async Task LoadSquidLinkCatalogAsync()
    {
        string? endpoint = Environment.GetEnvironmentVariable("SQUIDLINK_API_URL");
        if (string.IsNullOrWhiteSpace(endpoint))
        {
            await LoadSquidLinkPublicCatalogAsync();
            return;
        }

        using HttpResponseMessage response = await httpClient.GetAsync(endpoint);
        response.EnsureSuccessStatusCode();
        using JsonDocument document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());

        foreach (JsonElement item in EnumerateCatalogItems(document.RootElement))
        {
            string name = ReadString(item, "name", "title", "model", "profile");
            if (string.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            string category = NormalizeCategory(ReadString(item, "category", "type", "kind"), name);
            string filterUrl = ReadString(item, "filterUrl", "url", "rawUrl", "downloadUrl", "parametricEqUrl");
            string inlineContent = ReadString(item, "filter", "content", "eq", "parametricEq");
            if (string.IsNullOrWhiteSpace(filterUrl) && string.IsNullOrWhiteSpace(inlineContent))
            {
                continue;
            }

            if (allProfiles.Any(profile =>
                profile.Category.Equals(category, StringComparison.OrdinalIgnoreCase) &&
                profile.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            allProfiles.Add(new HeadphoneProfileOption(
                name.Trim(),
                category,
                filterUrl.Trim(),
                SquidLinkSource,
                string.IsNullOrWhiteSpace(inlineContent) ? null : inlineContent.Trim()));
        }
    }

    private async Task LoadSquidLinkPublicCatalogAsync()
    {
        const string defaultSquidLinkPhoneBookUrl = "https://squig.link/data/phone_book.json";
        using JsonDocument document = JsonDocument.Parse(await httpClient.GetStringAsync(defaultSquidLinkPhoneBookUrl));
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (JsonElement brand in document.RootElement.EnumerateArray())
        {
            if (!brand.TryGetProperty("phones", out JsonElement phones) || phones.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (JsonElement phone in phones.EnumerateArray())
            {
                string name = ReadString(phone, "name");
                if (string.IsNullOrWhiteSpace(name))
                {
                    continue;
                }

                string category = "IEMs";
                if (allProfiles.Any(profile =>
                    profile.Category.Equals(category, StringComparison.OrdinalIgnoreCase) &&
                    profile.Name.Equals(name, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }

                HeadphoneProfileOption? mappedAutoEq = FindBestAutoEqMatch(name, category);
                allProfiles.Add(new HeadphoneProfileOption(
                    name.Trim(),
                    category,
                    mappedAutoEq?.FilterUrl ?? string.Empty,
                    mappedAutoEq is null
                        ? $"{SquidLinkSource} (catalog only)"
                        : $"{SquidLinkSource} ({mappedAutoEq.Source.Replace($"{AutoEqSource}/", string.Empty, StringComparison.OrdinalIgnoreCase)})"));
            }
        }
    }

    private HeadphoneProfileOption? FindBestAutoEqMatch(string profileName, string category)
    {
        string normalizedProfileName = NormalizeForSearch(profileName);
        if (string.IsNullOrWhiteSpace(normalizedProfileName))
        {
            return null;
        }

        HeadphoneProfileOption? bestMatch = null;
        int bestScore = int.MinValue;
        List<string> tokens = normalizedProfileName.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();

        foreach (HeadphoneProfileOption option in allProfiles)
        {
            if (!option.Source.StartsWith($"{AutoEqSource}/", StringComparison.OrdinalIgnoreCase) ||
                !option.Category.Equals(category, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            string normalizedOptionName = NormalizeForSearch(option.Name);
            int score = 0;
            if (normalizedOptionName.Equals(normalizedProfileName, StringComparison.Ordinal))
            {
                score = 800;
            }
            else if (normalizedOptionName.StartsWith(normalizedProfileName, StringComparison.Ordinal) ||
                     normalizedProfileName.StartsWith(normalizedOptionName, StringComparison.Ordinal))
            {
                score = 420;
            }
            else if (normalizedOptionName.Contains(normalizedProfileName, StringComparison.Ordinal) ||
                     normalizedProfileName.Contains(normalizedOptionName, StringComparison.Ordinal))
            {
                score = 280;
            }
            else
            {
                int tokenHits = tokens.Count(token => normalizedOptionName.Contains(token, StringComparison.Ordinal));
                if (tokenHits == 0)
                {
                    continue;
                }

                score = (tokenHits * 70) - Math.Abs(normalizedOptionName.Length - normalizedProfileName.Length);
            }

            if (score > bestScore)
            {
                bestScore = score;
                bestMatch = option;
            }
        }

        return bestScore >= 180 ? bestMatch : null;
    }

    private void ApplyFilter()
    {
        string selectedCategory = (CategoryComboBox.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "All";
        List<string> queryTokens = TokenizeQuery(SearchBox.Text.Trim());
        bool queryMentionsHeadphones = queryTokens.Any(token => HeadphoneCategoryTerms.Contains(token));
        bool queryMentionsIems = queryTokens.Any(token => IemCategoryTerms.Contains(token));
        List<string> modelTokens = queryTokens
            .Where(token => !HeadphoneCategoryTerms.Contains(token) && !IemCategoryTerms.Contains(token))
            .ToList();
        string normalizedModelQuery = NormalizeForSearch(string.Join(' ', modelTokens));

        IEnumerable<HeadphoneProfileOption> scopedProfiles = allProfiles.Where(profile =>
        {
            if (queryMentionsHeadphones ^ queryMentionsIems)
            {
                return queryMentionsHeadphones
                    ? profile.Category.Equals("Headphones", StringComparison.OrdinalIgnoreCase)
                    : profile.Category.Equals("IEMs", StringComparison.OrdinalIgnoreCase);
            }

            return selectedCategory.Equals("All", StringComparison.OrdinalIgnoreCase) ||
                profile.Category.Equals(selectedCategory, StringComparison.OrdinalIgnoreCase);
        });

        List<HeadphoneProfileOption> rankedProfiles = scopedProfiles
            .Select(profile => new
            {
                Profile = profile,
                Score = ComputeMatchScore(profile, modelTokens, normalizedModelQuery),
                SourcePriority = profile.Source.StartsWith(ArtTuneSource, StringComparison.OrdinalIgnoreCase) ? 2 : 1
            })
            .Where(item => item.Score >= 0)
            .OrderByDescending(item => item.Score)
            .ThenByDescending(item => item.SourcePriority)
            .ThenBy(item => item.Profile.Name, StringComparer.OrdinalIgnoreCase)
            .Select(item => item.Profile)
            .ToList();

        visibleProfiles.Clear();
        visibleProfiles.AddRange(rankedProfiles);
        ProfileListBox.ItemsSource = null;
        ProfileListBox.ItemsSource = visibleProfiles;

        int autoEqCount = allProfiles.Count(profile => profile.Source.StartsWith($"{AutoEqSource}/", StringComparison.OrdinalIgnoreCase) ||
                                                       profile.Source.Equals(AutoEqSource, StringComparison.OrdinalIgnoreCase));
        int squidLinkCount = allProfiles.Count(profile => profile.Source.StartsWith(SquidLinkSource, StringComparison.OrdinalIgnoreCase));
        string scopeLabel = queryMentionsHeadphones ^ queryMentionsIems
            ? (queryMentionsHeadphones ? "Headphones" : "IEMs")
            : selectedCategory;
        int artTuneCount = allProfiles.Count(profile => profile.Source.StartsWith(ArtTuneSource, StringComparison.OrdinalIgnoreCase));
        string sourceLabel = squidLinkCount > 0
            ? $"{artTuneCount:N0} ArtTuneDB + {autoEqCount:N0} AutoEq + {squidLinkCount:N0} SquidLink"
            : $"{artTuneCount:N0} ArtTuneDB + {autoEqCount:N0} AutoEq";
        bool squidConfigured = !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("SQUIDLINK_API_URL"));
        StatusText.Text = squidConfigured
            ? $"{visibleProfiles.Count:N0} matches in {scopeLabel} ({sourceLabel})."
            : $"{visibleProfiles.Count:N0} matches in {scopeLabel} ({sourceLabel}; using public SquidLink catalog).";
    }

    private void CategoryComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (IsLoaded)
        {
            ApplyFilter();
        }
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (IsLoaded)
        {
            ApplyFilter();
        }
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        StatusText.Text = "Refreshing headset and IEM catalog...";
        await LoadCatalogAsync();
    }

    private async void ProfileListBox_MouseDoubleClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        await UseSelectedProfileAsync();
    }

    private async void UseProfile_Click(object sender, RoutedEventArgs e)
    {
        await UseSelectedProfileAsync();
    }

    private async Task UseSelectedProfileAsync()
    {
        if (ProfileListBox.SelectedItem is not HeadphoneProfileOption selected)
        {
            StatusText.Text = "Select a headphone or IEM profile first.";
            return;
        }

        try
        {
            string content;
            if (!string.IsNullOrWhiteSpace(selected.InlineFilterContent))
            {
                content = selected.InlineFilterContent;
            }
            else
            {
                if (string.IsNullOrWhiteSpace(selected.FilterUrl))
                {
                    StatusText.Text = "This SquidLink profile is listed, but no AutoEq parametric filter mapping was found yet.";
                    return;
                }

                StatusText.Text = $"Downloading {selected.Name} filters from {selected.Source}...";
                content = await httpClient.GetStringAsync(selected.FilterUrl);
            }

            if (!ContainsValidEqData(content))
            {
                throw new InvalidDataException("The downloaded profile contains no Equalizer APO filters.");
            }

            ProfileName = selected.Name;
            Category = selected.Category;
            FilterContent = content.Trim();

            if (TargetCurveComboBox.SelectedIndex > 0)
            {
                TargetCurveOption targetOption = TargetCurveOptions[TargetCurveComboBox.SelectedIndex];
                string targetPath = Path.Combine(AppContext.BaseDirectory, "targets", targetOption.FileName);
                if (!File.Exists(targetPath))
                {
                    throw new FileNotFoundException($"The bundled target curve was not found: {targetOption.FileName}", targetPath);
                }
                TargetCurveContent = await File.ReadAllTextAsync(targetPath);
                TargetCurveName = targetOption.Name;
            }

            DialogResult = true;
        }
        catch (HttpRequestException)
        {
            StatusText.Text = "That profile could not be downloaded. Check your internet connection and try again.";
        }
        catch (TaskCanceledException)
        {
            StatusText.Text = "Profile download timed out. Try again.";
        }
        catch (InvalidDataException)
        {
            StatusText.Text = "That profile did not contain valid Equalizer APO filters.";
        }
        catch (JsonException)
        {
            StatusText.Text = "That profile could not be downloaded or did not contain valid EQ filters.";
        }
    }

    private static IEnumerable<JsonElement> EnumerateCatalogItems(JsonElement root)
    {
        if (root.ValueKind == JsonValueKind.Array)
        {
            foreach (JsonElement item in root.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Object)
                {
                    yield return item;
                }
            }
            yield break;
        }

        if (root.ValueKind != JsonValueKind.Object)
        {
            yield break;
        }

        foreach (string key in new[] { "items", "results", "profiles", "data" })
        {
            if (!root.TryGetProperty(key, out JsonElement collection) || collection.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (JsonElement item in collection.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.Object)
                {
                    yield return item;
                }
            }
            yield break;
        }
    }

    private static string ReadString(JsonElement element, params string[] propertyNames)
    {
        foreach (string propertyName in propertyNames)
        {
            if (!element.TryGetProperty(propertyName, out JsonElement property) || property.ValueKind != JsonValueKind.String)
            {
                continue;
            }

            string? value = property.GetString();
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return string.Empty;
    }

    private static string NormalizeCategory(string categoryValue, string modelName)
    {
        string normalizedCategory = NormalizeForSearch(categoryValue);
        string compactCategory = normalizedCategory.Replace(" ", string.Empty, StringComparison.Ordinal);
        if (IemCategoryTerms.Any(term =>
            normalizedCategory.Contains(term, StringComparison.Ordinal) ||
            compactCategory.Contains(term, StringComparison.Ordinal)))
        {
            return "IEMs";
        }

        if (HeadphoneCategoryTerms.Any(term =>
            normalizedCategory.Contains(term, StringComparison.Ordinal) ||
            compactCategory.Contains(term, StringComparison.Ordinal)))
        {
            return "Headphones";
        }

        string normalizedModel = NormalizeForSearch(modelName);
        string compactModel = normalizedModel.Replace(" ", string.Empty, StringComparison.Ordinal);
        if (IemCategoryTerms.Any(term =>
            normalizedModel.Contains(term, StringComparison.Ordinal) ||
            compactModel.Contains(term, StringComparison.Ordinal)))
        {
            return "IEMs";
        }

        return "Headphones";
    }

    private static int ComputeMatchScore(HeadphoneProfileOption profile, IReadOnlyList<string> modelTokens, string normalizedModelQuery)
    {
        string normalizedName = NormalizeForSearch(profile.Name);
        if (modelTokens.Count == 0)
        {
            return profile.Source.Equals(SquidLinkSource, StringComparison.OrdinalIgnoreCase) ? 5 : 1;
        }

        int score = 0;
        int matchedTokens = 0;
        if (!string.IsNullOrWhiteSpace(normalizedModelQuery))
        {
            if (normalizedName.StartsWith(normalizedModelQuery, StringComparison.Ordinal))
            {
                score += 120;
            }
            else if (normalizedName.Contains(normalizedModelQuery, StringComparison.Ordinal))
            {
                score += 60;
            }
        }

        foreach (string token in modelTokens)
        {
            int index = normalizedName.IndexOf(token, StringComparison.Ordinal);
            if (index < 0)
            {
                continue;
            }

            matchedTokens++;
            score += index == 0 || normalizedName[index - 1] == ' ' ? 35 : 18;
        }

        if (matchedTokens == 0)
        {
            return -1;
        }

        score += matchedTokens * 20;
        score -= (modelTokens.Count - matchedTokens) * 6;

        if (profile.Source.StartsWith(SquidLinkSource, StringComparison.OrdinalIgnoreCase))
        {
            score += 6;
        }

        return score;
    }

    private static List<string> TokenizeQuery(string query)
    {
        string normalized = NormalizeForSearch(query);
        return string.IsNullOrWhiteSpace(normalized)
            ? new List<string>()
            : normalized.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
    }

    private static string NormalizeForSearch(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        char[] normalizedCharacters = value
            .ToLowerInvariant()
            .Select(character => char.IsLetterOrDigit(character) ? character : ' ')
            .ToArray();
        return string.Join(' ', new string(normalizedCharacters)
            .Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    private static bool ContainsValidEqData(string content)
    {
        return content
            .Split('\n')
            .Select(line => line.TrimStart())
            .Any(line =>
                line.StartsWith("Filter", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Preamp", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("GraphicEQ", StringComparison.OrdinalIgnoreCase));
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void Header_MouseLeftButtonDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (e.ChangedButton == System.Windows.Input.MouseButton.Left)
        {
            DragMove();
        }
    }
}
