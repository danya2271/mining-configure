Чтобы Watchdog мог переключать MSR без постоянного запроса пароля, тебе нужно разрешить выполнение wrmsr через sudo без пароля.
Выполни: sudo EDITOR=nano visudo и добавь в конец файла строку:
твой_юзернейм ALL=(ALL) NOPASSWD: /usr/bin/wrmsr
