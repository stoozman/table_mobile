import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'models/task.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await dotenv.load();
    
    // Initialize date formatting
    await initializeDateFormatting('ru');
    
    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );
    
    runApp(const MyApp());
  } catch (e) {
    debugPrint('Error in initialization: $e');
    rethrow;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tasks App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const TasksScreen(),
    );
  }
}

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<Task> tasks = [];
  bool isLoading = true;
  String? error;
  DateTime selectedDate = DateTime.now();
  final dateFormat = DateFormat('dd.MM.yyyy');
  
  String viewMode = 'day'; // 'day', 'week', 'month'
  late RealtimeChannel _tasksSubscription;

  @override
  void initState() {
    super.initState();
    _loadTasks();
    _subscribeToTasks();
  }

  void _subscribeToTasks() {
    _tasksSubscription = Supabase.instance.client
        .channel('public:tasks')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'tasks',
          callback: (payload) {
            _handleRealtimeEvent(payload);
          },
        )
        .subscribe();
  }

  void _handleRealtimeEvent(PostgresChangePayload payload) {
    if (!mounted) return;

    final startDate = _getStartDate();
    final endDate = _getEndDate();
    
    Map<String, dynamic> record;
    if (payload.eventType == PostgresChangeEvent.delete) {
      record = payload.oldRecord;
    } else {
      record = payload.newRecord;
    }
    
    final taskDate = DateTime.parse(record['date'] as String);

    // Проверяем, входит ли дата задачи в текущий период отображения
    if (taskDate.isBefore(startDate) || taskDate.isAfter(endDate)) {
      return;
    }

    setState(() {
      switch (payload.eventType) {
        case PostgresChangeEvent.insert:
          final newTask = Task.fromJson(payload.newRecord);
          tasks.add(newTask);
          tasks.sort((a, b) => b.isImportant == a.isImportant ? 0 : b.isImportant ? 1 : -1);
          break;
        case PostgresChangeEvent.update:
          final updatedTask = Task.fromJson(payload.newRecord);
          final index = tasks.indexWhere((t) => t.id == updatedTask.id);
          if (index != -1) {
            tasks[index] = updatedTask;
          }
          break;
        case PostgresChangeEvent.delete:
          final deletedId = payload.oldRecord['id'];
          tasks.removeWhere((t) => t.id == deletedId);
          break;
        case PostgresChangeEvent.all:
          // This case will never be triggered as we receive specific events
          break;
      }
    });
  }

  @override
  void dispose() {
    _tasksSubscription.unsubscribe();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime(2026),
    );
    if (picked != null && picked != selectedDate) {
      setState(() {
        selectedDate = picked;
      });
      _loadTasks();
    }
  }

  DateTime _getStartDate() {
    switch (viewMode) {
      case 'week':
        return selectedDate.subtract(Duration(days: selectedDate.weekday - 1));
      case 'month':
        return DateTime(selectedDate.year, selectedDate.month, 1);
      default:
        return selectedDate;
    }
  }

  DateTime _getEndDate() {
    switch (viewMode) {
      case 'week':
        final startDate = _getStartDate();
        return startDate.add(const Duration(days: 6));
      case 'month':
        return DateTime(selectedDate.year, selectedDate.month + 1, 0);
      default:
        return selectedDate;
    }
  }

  Future<void> _loadTasks() async {
    try {
      setState(() {
        isLoading = true;
        error = null;
      });

      final startDate = _getStartDate();
      final endDate = _getEndDate();

      final response = await Supabase.instance.client
          .from('tasks')
          .select()
          .gte('date', DateFormat('yyyy-MM-dd').format(startDate))
          .lte('date', DateFormat('yyyy-MM-dd').format(endDate))
          .order('is_important', ascending: false); // Сортируем по важности

      setState(() {
        tasks = (response as List<dynamic>)
            .map((task) => Task.fromJson(task))
            .toList();
        isLoading = false;
      });
    } catch (e) {
      debugPrint('Error loading tasks: $e');
      setState(() {
        isLoading = false;
        error = e.toString();
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading tasks: $e')),
        );
      }
    }
  }

  Future<void> _toggleTaskCompletion(Task task) async {
    try {
      final newStatus = !task.completed;
      
      await Supabase.instance.client
          .from('tasks')
          .update({'completed': newStatus})
          .eq('id', task.id);

      setState(() {
        final taskIndex = tasks.indexWhere((t) => t.id == task.id);
        if (taskIndex != -1) {
          tasks[taskIndex].completed = newStatus;
        }
      });
    } catch (e) {
      debugPrint('Error updating task: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка обновления задачи: $e')),
        );
      }
    }
  }

  Future<void> _updateTaskComment(Task task, String? newComment) async {
    try {
      await Supabase.instance.client
          .from('tasks')
          .update({'comment': newComment})
          .eq('id', task.id);

      setState(() {
        final taskIndex = tasks.indexWhere((t) => t.id == task.id);
        if (taskIndex != -1) {
          tasks[taskIndex] = task.copyWith(comment: newComment);
        }
      });
    } catch (e) {
      debugPrint('Error updating task comment: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка обновления комментария: $e')),
        );
      }
    }
  }

  Future<void> _showCommentDialog(Task task) async {
    final TextEditingController commentController = TextEditingController(text: task.comment);
    
    return showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Комментарий к задаче'),
          content: TextField(
            controller: commentController,
            decoration: const InputDecoration(
              hintText: 'Введите комментарий',
            ),
            maxLines: null,
            keyboardType: TextInputType.multiline,
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () {
                _updateTaskComment(task, commentController.text.trim());
                Navigator.of(context).pop();
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    String periodText;
    switch (viewMode) {
      case 'week':
        final startDate = _getStartDate();
        final endDate = _getEndDate();
        periodText = '${dateFormat.format(startDate)} - ${dateFormat.format(endDate)}';
        break;
      case 'month':
        periodText = DateFormat('MMMM yyyy', 'ru').format(selectedDate);
        break;
      default:
        periodText = dateFormat.format(selectedDate);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Задачи'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.calendar_view_day),
            onSelected: (String mode) {
              setState(() {
                viewMode = mode;
              });
              _loadTasks();
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'day',
                child: Text('День'),
              ),
              const PopupMenuItem<String>(
                value: 'week',
                child: Text('Неделя'),
              ),
              const PopupMenuItem<String>(
                value: 'month',
                child: Text('Месяц'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios),
                  onPressed: () {
                    setState(() {
                      switch (viewMode) {
                        case 'week':
                          selectedDate = selectedDate.subtract(const Duration(days: 7));
                          break;
                        case 'month':
                          selectedDate = DateTime(selectedDate.year, selectedDate.month - 1, 1);
                          break;
                        default:
                          selectedDate = selectedDate.subtract(const Duration(days: 1));
                      }
                    });
                    _loadTasks();
                  },
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _selectDate(context),
                    child: Text(
                      periodText,
                      style: const TextStyle(fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios),
                  onPressed: () {
                    setState(() {
                      switch (viewMode) {
                        case 'week':
                          selectedDate = selectedDate.add(const Duration(days: 7));
                          break;
                        case 'month':
                          selectedDate = DateTime(selectedDate.year, selectedDate.month + 1, 1);
                          break;
                        default:
                          selectedDate = selectedDate.add(const Duration(days: 1));
                      }
                    });
                    _loadTasks();
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('Ошибка: $error'),
                            ElevatedButton(
                              onPressed: _loadTasks,
                              child: const Text('Повторить'),
                            ),
                          ],
                        ),
                      )
                    : tasks.isEmpty
                        ? Center(
                            child: Text(
                              viewMode == 'day'
                                  ? 'Нет задач на выбранную дату'
                                  : viewMode == 'week'
                                      ? 'Нет задач на выбранную неделю'
                                      : 'Нет задач на выбранный месяц',
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadTasks,
                            child: ListView.builder(
                              itemCount: tasks.length,
                              itemBuilder: (context, index) {
                                final task = tasks[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: ListTile(
                                    onTap: () => _showCommentDialog(task),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            task.productName,
                                            style: TextStyle(
                                              fontWeight: task.isImportant
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                            ),
                                          ),
                                        ),
                                        if (task.isImportant)
                                          const Icon(
                                            Icons.star,
                                            color: Colors.amber,
                                          ),
                                      ],
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (viewMode != 'day')
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(
                                              dateFormat.format(task.date),
                                              style: TextStyle(
                                                color: Colors.grey[600],
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        if (task.comment != null && task.comment!.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Text(task.comment!),
                                          ),
                                        if (task.repeatType != 'none')
                                          Padding(
                                            padding: const EdgeInsets.only(top: 4),
                                            child: Icon(
                                              Icons.repeat,
                                              size: 16,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                      ],
                                    ),
                                    leading: Checkbox(
                                      value: task.completed,
                                      onChanged: (bool? value) => _toggleTaskCompletion(task),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
