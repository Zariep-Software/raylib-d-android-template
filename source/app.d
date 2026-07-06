module app;
import raylib;

struct Slider
{
	Rectangle bounds;
	float value;
	bool isDragging;
}

void runGame()
{
	// Force native mobile scaling immediately by initializing with 0, 0 on Android
	version(Android)
	{
		InitWindow(0, 0, "raylib-d Sandbox (Android)");
	}
	else
	{
		InitWindow(800, 600, "raylib-d Sandbox (Desktop)");
	}

	InitAudioDevice();
	SetTargetFPS(60);

	// Media Asset Loading //
	// in android, /assets is a prefix for the app assets, they should be
	// at /app/src/main/assets

	Texture2D sprite = LoadTexture("assets/sprite.png");
	Music bgm = LoadMusicStream("assets/audio.ogg");

	// Fallback if the files aren't found, preventing a hard crash
	bool assetsValid = (sprite.id > 0);

	Slider slider = Slider(Rectangle(0, 0, 200, 30), 0.5f, false);
	Color uiColor = Colors.LIME;

	while (!WindowShouldClose())
	{
		UpdateMusicStream(bgm);

		float sw = cast(float)GetScreenWidth();
		float sh = cast(float)GetScreenHeight();

		Vector2 inputPos = GetMousePosition();

		Rectangle btnPlay = Rectangle(sw * 0.5f - 110, sh * 0.45f, 220, 50);
		bool btnPlayHovered = CheckCollisionPointRec(inputPos, btnPlay);

		slider.bounds = Rectangle(sw * 0.5f - 100, sh * 0.60f, 200, 25);

		if (IsMouseButtonPressed(MouseButton.MOUSE_BUTTON_LEFT))
		{
			if (btnPlayHovered)
			{
				if (IsMusicStreamPlaying(bgm)) StopMusicStream(bgm);
				PlayMusicStream(bgm);
				uiColor = Colors.MAROON;
			}
			if (CheckCollisionPointRec(inputPos, slider.bounds))
			{
				slider.isDragging = true;
			}
		}

		if (IsMouseButtonDown(MouseButton.MOUSE_BUTTON_LEFT) && slider.isDragging)
		{
			slider.value = (inputPos.x - slider.bounds.x) / slider.bounds.width;
			if (slider.value < 0.0f) slider.value = 0.0f;
			if (slider.value > 1.0f) slider.value = 1.0f;

			SetMusicVolume(bgm, slider.value);
		}

		if (IsMouseButtonReleased(MouseButton.MOUSE_BUTTON_LEFT))
		{
			slider.isDragging = false;
		}

		BeginDrawing();
		ClearBackground(Colors.DARKGRAY);

		version(Android)
		{
			DrawText("ENV: Android NDK Native View", 20, 20, 20, Colors.GREEN);
		}
		else
		{
			DrawText("ENV: Desktop Native Window", 20, 20, 20, Colors.ORANGE);
		}

		if (assetsValid)
		{
			DrawTexture(sprite, cast(int)(sw * 0.5f - sprite.width * 0.5f), cast(int)(sh * 0.15f), Colors.WHITE);
		}
		else
		{
			DrawRectangle(cast(int)(sw * 0.5f - 40), cast(int)(sh * 0.15f), 80, 80, Colors.LIGHTGRAY);
			DrawText("Missing\n'assets/sprite.png'", cast(int)(sw * 0.5f - 75), cast(int)(sh * 0.15f + 25), 16, Colors.RED);
		}

		DrawRectangleRounded(btnPlay, 0.2f, 4, btnPlayHovered ? Colors.GRAY : uiColor);
		DrawText("PLAY AUDIO.OGG", cast(int)(btnPlay.x + 25), cast(int)(btnPlay.y + 15), 18, Colors.WHITE);

		DrawRectangleRec(slider.bounds, Colors.LIGHTGRAY);
		DrawRectangle(cast(int)slider.bounds.x, cast(int)slider.bounds.y, cast(int)(slider.bounds.width * slider.value), cast(int)slider.bounds.height, Colors.LIME);
		DrawRectangleLinesEx(slider.bounds, 2, Colors.DARKGRAY);
		DrawText(TextFormat("Volume: %i%%", cast(int)(slider.value * 100)), cast(int)slider.bounds.x, cast(int)(slider.bounds.y + 35), 16, Colors.RAYWHITE);

		EndDrawing();
	}

	if (assetsValid) UnloadTexture(sprite);
	UnloadMusicStream(bgm);
	CloseAudioDevice();
	CloseWindow();
}

extern(C) int main(int argc, char** argv)
{
	runGame();
	return 0;
}