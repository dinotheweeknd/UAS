import 'dart:async';
import 'dart:convert';
import 'dart:math'; // Untuk Random Cuaca
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const FloodApp());
}

class FloodApp extends StatelessWidget {
  const FloodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pantau Banjir Medan',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D47A1),
          brightness: Brightness.light,
        ),
        textTheme: GoogleFonts.poppinsTextTheme(Theme.of(context).textTheme),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _jalanController = TextEditingController();

  // Koordinat Default (Medan)
  LatLng _currentLocation = const LatLng(3.5952, 98.6722);
  String _selectedLevel = "Sedang";
  String _vehicleStatus = "Bisa Semua";
  String _activeFilter = "Semua"; // Filter Aktif

  List<dynamic> _searchResults = [];
  Timer? _debounce;
  bool _isSearching = false;

  // Variabel Cuaca Dummy
  String _cuacaText = "Cerah ☀️";
  int _suhu = 30;

  @override
  void initState() {
    super.initState();
    _determinePosition();
    _generateRandomWeather(); // Generate cuaca saat aplikasi dibuka
  }

  // --- FUNGSI GENERATE CUACA (SIMULASI) ---
  void _generateRandomWeather() {
    final List<String> kondisi = [
      'Cerah ☀️',
      'Berawan ☁️',
      'Hujan 🌦️',
      'Mendung 🌥️',
      'Badai ⛈️',
    ];
    setState(() {
      _cuacaText = kondisi[Random().nextInt(kondisi.length)];
      _suhu = 26 + Random().nextInt(8); // Random suhu 26-33
    });
  }

  // --- FUNGSI ANIMASI PETA (GLIDING) ---
  void _animatedMapMove(LatLng destLocation, double destZoom) {
    final latTween = Tween<double>(
      begin: _mapController.camera.center.latitude,
      end: destLocation.latitude,
    );
    final lngTween = Tween<double>(
      begin: _mapController.camera.center.longitude,
      end: destLocation.longitude,
    );
    final zoomTween = Tween<double>(
      begin: _mapController.camera.zoom,
      end: destZoom,
    );

    // Durasi dipercepat jadi 800ms biar sat-set
    final controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    final Animation<double> animation = CurvedAnimation(
      parent: controller,
      curve: Curves.fastOutSlowIn,
    );

    controller.addListener(() {
      _mapController.move(
        LatLng(latTween.evaluate(animation), lngTween.evaluate(animation)),
        zoomTween.evaluate(animation),
      );
    });

    animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) controller.dispose();
    });
    controller.forward();
  }

  // --- 1. AUTO-FILL ALAMAT ---
  Future<void> _getAddressFromLatLng(double lat, double lon) async {
    try {
      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=18&addressdetails=1',
      );
      final response = await http.get(
        url,
        headers: {'User-Agent': 'com.example.pantau_banjir'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final address = data['address'];
        String namaTempat =
            address['amenity'] ?? address['shop'] ?? address['building'] ?? "";
        String namaJalan = address['road'] ??
            address['residential'] ??
            address['path'] ??
            address['footway'] ??
            "";
        String hasilAlamat = [
          namaTempat,
          namaJalan,
        ].where((s) => s.isNotEmpty).join(", ");

        if (hasilAlamat.isEmpty) hasilAlamat = "Lokasi Tidak Dikenal";
        setState(() {
          _jalanController.text = hasilAlamat;
        });
      }
    } catch (e) {
      debugPrint("Gagal ambil alamat: $e");
    }
  }

  // --- 2. PENCARIAN ---
  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 1000), () {
      if (query.isNotEmpty)
        _fetchSuggestions(query);
      else
        setState(() => _searchResults = []);
    });
  }

  Future<void> _fetchSuggestions(String query) async {
    setState(() => _isSearching = true);
    try {
      final String lat = _currentLocation.latitude.toString();
      final String lon = _currentLocation.longitude.toString();
      final String viewbox = "98.50,3.85,98.90,3.30"; // Area Medan

      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=$query&format=json&addressdetails=1&limit=10&lat=$lat&lon=$lon&viewbox=$viewbox&bounded=1&countrycodes=id',
      );

      final response = await http.get(
        url,
        headers: {'User-Agent': 'com.example.pantau_banjir'},
      );
      if (response.statusCode == 200)
        setState(() {
          _searchResults = json.decode(response.body);
        });
    } catch (e) {
      debugPrint("Error: $e");
    } finally {
      setState(() => _isSearching = false);
    }
  }

  void _selectLocation(dynamic locationData) {
    final lat = double.parse(locationData['lat']);
    final lon = double.parse(locationData['lon']);

    final address = locationData['address'];
    String namaTempat = address['amenity'] ?? address['shop'] ?? "";
    String namaJalan =
        address['road'] ?? address['residential'] ?? address['path'] ?? "";
    String hasilNama = [
      namaTempat,
      namaJalan,
    ].where((s) => s.isNotEmpty).join(", ");

    setState(() {
      _currentLocation = LatLng(lat, lon);
      _searchResults = [];
      _searchController.clear();
      if (hasilNama.isNotEmpty) _jalanController.text = hasilNama;
    });

    _animatedMapMove(LatLng(lat, lon), 17.0);
    FocusScope.of(context).unfocus();
  }

  // --- 3. GPS ---
  Future<void> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("⚠️ GPS Mati"),
          content: const Text(
            "Tolong nyalakan GPS agar aplikasi berjalan maksimal.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Nanti"),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Geolocator.openLocationSettings();
              },
              child: const Text("Buka Setting"),
            ),
          ],
        ),
      );
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    Position position = await Geolocator.getCurrentPosition();
    setState(() {
      _currentLocation = LatLng(position.latitude, position.longitude);
    });
    _animatedMapMove(_currentLocation, 16.0);
    _getAddressFromLatLng(position.latitude, position.longitude);
  }

  // --- 4. KIRIM LAPORAN ---
  Future<void> _sendReportToFirebase() async {
    if (_jalanController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("⚠️ Nama jalan belum terisi!")),
      );
      return;
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Mengirim laporan...")));

    try {
      String customDocId = _jalanController.text
          .trim()
          .toLowerCase()
          .replaceAll(' ', '_')
          .replaceAll(',', '')
          .replaceAll('.', '');
      await FirebaseFirestore.instance
          .collection('laporan_banjir')
          .doc(customDocId)
          .set({
        'nama_jalan': _jalanController.text.trim(),
        'lokasi': GeoPoint(
          _currentLocation.latitude,
          _currentLocation.longitude,
        ),
        'level': _selectedLevel,
        'status_jalan': _vehicleStatus,
        'waktu': FieldValue.serverTimestamp(),
        'status': 'Menunggu Verifikasi',
      });
      _jalanController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("✅ Laporan berhasil diupdate!"),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("❌ Gagal: $e"), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('laporan_banjir')
            .orderBy('waktu', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          List<Marker> allMarkers = [];
          String statusTeks = "Lokasi Aman • Jalan Lancar";
          Color statusWarna = Colors.blue;
          IconData statusIcon = Icons.verified_user;
          Color backgroundWarna = Colors.white;
          bool latestReportFound = false;

          // Marker User
          allMarkers.add(
            Marker(
              point: _currentLocation,
              width: 80,
              height: 80,
              child: const Icon(
                Icons.person_pin_circle,
                color: Colors.blue,
                size: 50,
              ),
            ),
          );

          if (snapshot.hasData) {
            for (var doc in snapshot.data!.docs) {
              final data = doc.data() as Map<String, dynamic>;

              // LOGIKA WAKTU (Expire)
              final Timestamp? timestamp = data['waktu'];
              if (timestamp == null) continue;
              final DateTime waktuLapor = timestamp.toDate();
              final DateTime sekarang = DateTime.now();
              final Duration selisih = sekarang.difference(waktuLapor);

              if (selisih.inHours >= 3) continue; // Hapus kalau > 3 jam
              bool isOldData = selisih.inHours >= 1; // Tandai tua kalau > 1 jam

              if (data['lokasi'] != null) {
                final GeoPoint lokasi = data['lokasi'];
                final String level = data['level'] ?? 'Sedang';
                final String jalanInfo = data['status_jalan'] ?? 'Bisa Semua';
                final String namaJalanDisplay =
                    data['nama_jalan'] ?? 'Tanpa Nama';

                // FILTERING TAMPILAN
                if (_activeFilter == "Bahaya" && level != "Bahaya") continue;
                if (_activeFilter == "Aman" && level == "Bahaya") continue;

                double jarakMeter = Geolocator.distanceBetween(
                  _currentLocation.latitude,
                  _currentLocation.longitude,
                  lokasi.latitude,
                  lokasi.longitude,
                );

                // LOGIKA STATUS BAR (Hanya respon data baru < 1 jam)
                if (jarakMeter < 1000 && !latestReportFound && !isOldData) {
                  if (jalanInfo == 'Lumpuh Total' || level == 'Bahaya') {
                    statusTeks = "⛔ BAHAYA! $namaJalanDisplay Lumpuh!";
                    statusWarna = Colors.red;
                    statusIcon = Icons.dangerous;
                    backgroundWarna = Colors.red.shade50;
                  } else if (jalanInfo == 'Cuma Truk' || level == 'Sedang') {
                    statusTeks = "⚠️ WASPADA! $namaJalanDisplay Banjir";
                    statusWarna = Colors.orange.shade800;
                    statusIcon = Icons.warning_amber_rounded;
                    backgroundWarna = Colors.orange.shade50;
                  } else {
                    statusTeks = "Genangan Rendah di $namaJalanDisplay";
                    statusWarna = Colors.green;
                    statusIcon = Icons.info_outline;
                  }
                  latestReportFound = true;
                }

                // LOGIKA WARNA PIN
                Color pinColor;
                if (isOldData) {
                  pinColor = Colors.grey;
                } else {
                  if (level == 'Bahaya')
                    pinColor = Colors.red;
                  else if (level == 'Rendah')
                    pinColor = Colors.green;
                  else
                    pinColor = Colors.orange;
                }

                allMarkers.add(
                  Marker(
                    point: LatLng(lokasi.latitude, lokasi.longitude),
                    width: 140,
                    height: 100,
                    child: Column(
                      children: [
                        Icon(Icons.location_on, color: pinColor, size: 40),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey.shade300),
                            boxShadow: [
                              BoxShadow(blurRadius: 2, color: Colors.black12),
                            ],
                          ),
                          child: Column(
                            children: [
                              Text(
                                namaJalanDisplay,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                isOldData
                                    ? "Surut? (${selisih.inHours}j lalu)"
                                    : "$level • $jalanInfo",
                                style: TextStyle(
                                  fontSize: 9,
                                  color: pinColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
            }
          }

          return Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _currentLocation,
                  initialZoom: 13.0,
                  onPositionChanged: (pos, gesture) {
                    if (gesture && _searchResults.isNotEmpty) {
                      setState(() {
                        _searchResults = [];
                        FocusScope.of(context).unfocus();
                      });
                    }
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.pantau_banjir',
                  ),
                  MarkerLayer(markers: allMarkers),
                ],
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // --- 1. WIDGET CUACA (Simulasi) ---
                      _buildRealWeather(),

                      const SizedBox(height: 10),

                      // --- 2. SEARCH BAR ---
                      _buildSearchBar(),

                      // --- 3. FILTER BUTTONS ---
                      if (_searchResults.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _buildFilterButton("Semua", Colors.blue),
                                const SizedBox(width: 8),
                                _buildFilterButton("Bahaya", Colors.red),
                                const SizedBox(width: 8),
                                _buildFilterButton("Aman", Colors.green),
                              ],
                            ),
                          ),
                        ),

                      if (_searchResults.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 10,
                                offset: Offset(0, 5),
                              ),
                            ],
                          ),
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: ListView.separated(
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            itemCount: _searchResults.length,
                            separatorBuilder: (ctx, i) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = _searchResults[index];
                              final double lat = double.parse(item['lat']);
                              final double lon = double.parse(item['lon']);
                              double distanceInMeters =
                                  Geolocator.distanceBetween(
                                _currentLocation.latitude,
                                _currentLocation.longitude,
                                lat,
                                lon,
                              );
                              String distanceText = distanceInMeters < 1000
                                  ? "${distanceInMeters.toStringAsFixed(0)} m"
                                  : "${(distanceInMeters / 1000).toStringAsFixed(1)} km";

                              return ListTile(
                                leading: const Icon(
                                  Icons.location_on_outlined,
                                  color: Colors.grey,
                                ),
                                title: Text(
                                  item['display_name'].split(',')[0],
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  item['display_name'],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  distanceText,
                                  style: const TextStyle(
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                onTap: () => _selectLocation(item),
                              );
                            },
                          ),
                        ),

                      if (_searchResults.isEmpty)
                        _buildFloodAlert(
                          statusTeks,
                          statusWarna,
                          statusIcon,
                          backgroundWarna,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: "gps_btn",
            onPressed: _determinePosition,
            backgroundColor: Colors.white,
            child: const Icon(Icons.my_location, color: Colors.blue),
          ),
          const SizedBox(height: 16),
          FloatingActionButton.extended(
            heroTag: "lapor_btn",
            onPressed: () {
              _getAddressFromLatLng(
                _currentLocation.latitude,
                _currentLocation.longitude,
              );
              _showReportModal(context);
            },
            label: const Text("Lapor Banjir"),
            icon: const Icon(Icons.add_location_alt_outlined),
            backgroundColor: Colors.red[700],
            foregroundColor: Colors.white,
          ),
        ],
      ),
    );
  }

  // --- WIDGET HELPER ---

  Widget _buildRealWeather() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _cuacaText.contains('Hujan') || _cuacaText.contains('Badai')
                ? Icons.thunderstorm
                : Icons.wb_sunny,
            color: _cuacaText.contains('Hujan') || _cuacaText.contains('Badai')
                ? Colors.grey
                : Colors.orangeAccent,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            "Medan • $_cuacaText • $_suhu°C",
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          const BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          hintText: "Cari toko/gang terdekat...",
          prefixIcon: _isSearching
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : const Icon(Icons.location_on, color: Colors.redAccent),
          suffixIcon: IconButton(
            icon: const Icon(Icons.clear, color: Colors.grey),
            onPressed: () {
              _searchController.clear();
              setState(() => _searchResults = []);
            },
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 15,
          ),
        ),
      ),
    );
  }

  Widget _buildFloodAlert(
    String teks,
    Color warnaIkon,
    IconData ikon,
    Color warnaBackground,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: warnaBackground.withOpacity(0.95),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
        border: Border.all(color: warnaIkon.withOpacity(0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ikon, size: 24, color: warnaIkon),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              teks,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.black87,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterButton(String label, Color color) {
    bool isActive = _activeFilter == label;
    return GestureDetector(
      onTap: () {
        setState(() {
          _activeFilter = label;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? color : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ],
          border: Border.all(color: isActive ? color : Colors.grey.shade300),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.white : Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  void _showReportModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 20,
                right: 20,
                top: 10,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Lapor Kondisi",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _jalanController,
                      decoration: InputDecoration(
                        labelText: "Nama Jalan / Gang",
                        hintText: "Sedang mengambil alamat...",
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        prefixIcon: const Icon(Icons.edit_road),
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => _jalanController.clear(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Tinggi Air:",
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildChip("Rendah", Colors.green, setModalState, true),
                        _buildChip(
                          "Sedang",
                          Colors.orange,
                          setModalState,
                          true,
                        ),
                        _buildChip("Bahaya", Colors.red, setModalState, true),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "Kondisi Jalan:",
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      children: [
                        _buildChip(
                          "Bisa Semua",
                          Colors.blue,
                          setModalState,
                          false,
                        ),
                        _buildChip(
                          "Cuma Truk",
                          Colors.purple,
                          setModalState,
                          false,
                        ),
                        _buildChip(
                          "Lumpuh Total",
                          Colors.black,
                          setModalState,
                          false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _sendReportToFirebase,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0D47A1),
                        ),
                        child: const Text("Kirim Laporan"),
                      ),
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildChip(
    String label,
    Color color,
    StateSetter setModalState,
    bool isLevelSelector,
  ) {
    bool isSelected =
        isLevelSelector ? (_selectedLevel == label) : (_vehicleStatus == label);
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (bool selected) {
        setModalState(() {
          if (isLevelSelector)
            _selectedLevel = label;
          else
            _vehicleStatus = label;
        });
      },
      selectedColor: color.withOpacity(0.3),
      labelStyle: TextStyle(
        color: isSelected ? color : Colors.grey,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
