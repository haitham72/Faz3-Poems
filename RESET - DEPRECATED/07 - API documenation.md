# Library API Documentation

**Base URL**: `https://uffjlburuvsnstvgyito.supabase.co/functions/v1`

## Authentication

Include these headers in all requests:

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVmZmpsYnVydXZzbnN0dmd5aXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzY5NTM3NDgsImV4cCI6MjA1MjUyOTc0OH0.Esu6XQtAnxlHXXNTgbK-Rg_-TZW6Hhv7yyYVwMJE7fQ
apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVmZmpsYnVydXZzbnN0dmd5aXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzY5NTM3NDgsImV4cCI6MjA1MjUyOTc0OH0.Esu6XQtAnxlHXXNTgbK-Rg_-TZW6Hhv7yyYVwMJE7fQ
Content-Type: application/json
```

---

## 1. Get Library Categories

**Endpoint**: `POST /category`

**Description**: Returns all main categories for the Library home screen.

**Request**:

```bash
curl -X POST https://uffjlburuvsnstvgyito.supabase.co/functions/v1/category \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVmZmpsYnVydXZzbnN0dmd5aXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzY5NTM3NDgsImV4cCI6MjA1MjUyOTc0OH0.Esu6XQtAnxlHXXNTgbK-Rg_-TZW6Hhv7yyYVwMJE7fQ" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVmZmpsYnVydXZzbnN0dmd5aXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzY5NTM3NDgsImV4cCI6MjA1MjUyOTc0OH0.Esu6XQtAnxlHXXNTgbK-Rg_-TZW6Hhv7yyYVwMJE7fQ" \
  -H "Content-Type: application/json" \
  -d '{}'
```

**Response**:

```json
[
  {
    "ID": 14,
    "Carousel_Group_text_EN": "People",
    "Carousel_Group_text_AR": "أشخاص",
    "url_thumbnail_view": "https://uffjlburuvsnstvgyito.supabase.co/storage/v1/object/public/Diwan_Hamdan/Cateories/thumbnail_view/People_thumbnail_view.jpg"
  },
  {
    "ID": 15,
    "Carousel_Group_text_EN": "animals",
    "Carousel_Group_text_AR": "حيوانات",
    "url_thumbnail_view": "https://uffjlburuvsnstvgyito.supabase.co/storage/v1/object/public/Diwan_Hamdan/Cateories/thumbnail_view/animals_thumbnail_view.jpg"
  }
]
```

**Response Fields**:

- `ID`: Unique identifier
- `Carousel_Group_text_EN`: Category name (English)
- `Carousel_Group_text_AR`: Category name (Arabic)
- `url_thumbnail_view`: Thumbnail image URL (9:16 aspect ratio)

---

## 2. Get Subcategories

**Endpoint**: `POST /subcategory`

**Description**: Returns all items within a selected category.

**Request**:

```bash
curl -X POST https://uffjlburuvsnstvgyito.supabase.co/functions/v1/subcategory \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVmZmpsYnVydXZzbnN0dmd5aXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzY5NTM3NDgsImV4cCI6MjA1MjUyOTc0OH0.Esu6XQtAnxlHXXNTgbK-Rg_-TZW6Hhv7yyYVwMJE7fQ" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVmZmpsYnVydXZzbnN0dmd5aXRvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzY5NTM3NDgsImV4cCI6MjA1MjUyOTc0OH0.Esu6XQtAnxlHXXNTgbK-Rg_-TZW6Hhv7yyYVwMJE7fQ" \
  -H "Content-Type: application/json" \
  -d '{"category": "People"}'
```

**Request Body**:

```json
{
  "category": "People"
}
```

_Use `Carousel_Group_text_EN` value from the category response_

**Response**:

```json
[
  {
    "ID": 35,
    "Category_EN": "People",
    "Category_AR": "أشخاص",
    "subcategory_text_en": "Sheikh Zayed",
    "subcategory_text_ar": "الشيخ زايد",
    "url_thumbnail_view": "https://uffjlburuvsnstvgyito.supabase.co/storage/v1/object/public/Diwan_Hamdan/Cateories/thumbnail_view/People_Sheikh_Zayed_thumbnail_view.jpg",
    "url_focus": "https://uffjlburuvsnstvgyito.supabase.co/storage/v1/object/public/Diwan_Hamdan/Cateories/Focus/People_Sheikh_Zayed_Focus.jpg"
  },
  {
    "ID": 36,
    "Category_EN": "People",
    "Category_AR": "أشخاص",
    "subcategory_text_en": "Sheikh Rashid",
    "subcategory_text_ar": "الشيخ راشد",
    "url_thumbnail_view": "https://uffjlburuvsnstvgyito.supabase.co/storage/v1/object/public/Diwan_Hamdan/Cateories/thumbnail_view/People_Sheikh_Rashid_thumbnail_view.jpg",
    "url_focus": "https://uffjlburuvsnstvgyito.supabase.co/storage/v1/object/public/Diwan_Hamdan/Cateories/Focus/People_Sheikh_Rashid_Focus.jpg"
  }
]
```

**Response Fields**:

- `ID`: Unique identifier
- `Category_EN`: Parent category (English)
- `Category_AR`: Parent category (Arabic)
- `subcategory_text_en`: Item title (English)
- `subcategory_text_ar`: Item title (Arabic)
- `url_thumbnail_view`: Thumbnail image URL (9:16 aspect ratio)
- `url_focus`: Large focus/hero image URL (9:16 aspect ratio)

---

## Implementation Flow

1. **App Launch** → Call `/category` to display Library home screen
2. **User taps category** → Call `/subcategory` with `category` parameter
3. **Display first item** → Show `url_focus` as hero image with `subcategory_text_en/ar` as title
4. **Display remaining items** → Show as thumbnail grid with `url_thumbnail_view`

---

## Language Support

All responses include both English (`_EN`) and Arabic (`_AR`) fields. Select the appropriate field based on user's language preference.

---

## Image Aspect Ratio

All images are **9:16 (portrait)** aspect ratio.

---

## Error Handling

**400 Bad Request**:

```json
{
  "error": "category parameter required"
}
```

**500 Internal Server Error**:

```json
{
  "error": "Database error message"
}
```

---

## Swift Example

```swift
struct LibraryCategory: Codable {
    let ID: Int
    let Carousel_Group_text_EN: String
    let Carousel_Group_text_AR: String
    let url_thumbnail_view: String
}

struct Subcategory: Codable {
    let ID: Int
    let Category_EN: String
    let Category_AR: String
    let subcategory_text_en: String
    let subcategory_text_ar: String
    let url_thumbnail_view: String
    let url_focus: String
}

func fetchCategories() async throws -> [LibraryCategory] {
    let url = URL(string: "https://uffjlburuvsnstvgyito.supabase.co/functions/v1/category")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer eyJhbGci...", forHTTPHeaderField: "Authorization")
    request.setValue("eyJhbGci...", forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = "{}".data(using: .utf8)

    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode([LibraryCategory].self, from: data)
}

func fetchSubcategories(category: String) async throws -> [Subcategory] {
    let url = URL(string: "https://uffjlburuvsnstvgyito.supabase.co/functions/v1/subcategory")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer eyJhbGci...", forHTTPHeaderField: "Authorization")
    request.setValue("eyJhbGci...", forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = ["category": category]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, _) = try await URLSession.shared.data(for: request)
    return try JSONDecoder().decode([Subcategory].self, from: data)
}
```
