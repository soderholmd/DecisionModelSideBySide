"""Default scenarios: each has a data.config file and a default set of labels."""

from pathlib import Path

DATA_DIR = Path(__file__).parent / "data"

SCENARIOS = {
    "customer": {
        "name": "Customer questions & complaints",
        "description": "Route incoming customer messages to the right Microsoft sales or support team.",
        "data_file": DATA_DIR / "customer" / "data.config",
        "labels": [
            {"name": "Sales - New Purchase", "description": "Wants to buy a product, subscription, or license, or asks about pricing and quotes."},
            {"name": "Sales - Product Comparison", "description": "Asks which product, plan, or edition fits their needs, or compares offerings."},
            {"name": "Billing & Licensing", "description": "Questions or complaints about invoices, charges, refunds, renewals, or license assignment."},
            {"name": "Technical Support", "description": "Needs help with an error, outage, installation, configuration, or something not working."},
            {"name": "Account & Access", "description": "Sign-in problems, password resets, MFA, locked or compromised accounts."},
            {"name": "Feedback & Complaints", "description": "General complaints, praise, or feedback about service or experience, without a specific request."},
            {"name": "Other", "description": "Anything that does not fit the other categories."},
        ],
    },
    "expenses": {
        "name": "Expense report classification",
        "description": "Categorize expense report line items for reimbursement and accounting.",
        "data_file": DATA_DIR / "expenses" / "data.config",
        "labels": [
            {"name": "Lodging", "description": "Hotels, resorts, short-term rentals, and related room charges or fees."},
            {"name": "Airfare", "description": "Flights, airline tickets, seat upgrades, and baggage fees."},
            {"name": "Ground Transportation", "description": "Taxis, Uber/Lyft rides, trains, buses, parking, tolls, and fuel."},
            {"name": "Car Rental", "description": "Rental car charges, rental insurance, and rental car fuel or fees."},
            {"name": "Meals & Entertainment", "description": "Restaurants, coffee, room service, client dinners, and entertainment."},
            {"name": "Office Supplies & Equipment", "description": "Stationery, printing, hardware, peripherals, and other supplies."},
            {"name": "Software & Subscriptions", "description": "Software licenses, SaaS subscriptions, and online services."},
            {"name": "Conferences & Training", "description": "Event registrations, conference fees, courses, and certifications."},
            {"name": "Communications", "description": "Phone, mobile data, roaming, and internet or Wi-Fi charges."},
            {"name": "Other", "description": "Anything that does not fit the other categories."},
        ],
    },
    "students": {
        "name": "Student enquiry routing",
        "description": "Route fictional university student enquiries to the right team by the main help requested. For demonstration only, not admissions decisions or wellbeing triage.",
        "data_file": DATA_DIR / "students" / "data.config",
        "labels": [
            {"name": "Admissions", "description": "Applications, entry requirements, offers, supporting documents, deferrals and transferring into a degree programme. Route technical sign-in or upload failures to IT Support."},
            {"name": "Fees & Funding", "description": "Tuition fees, invoices, payment plans, scholarships, bursaries, student loans and hardship funding. Use this when the main request is financial assistance."},
            {"name": "Accommodation", "description": "University housing applications, room allocations, tenancy contracts, moving in, room changes and repairs in student residences."},
            {"name": "Timetabling", "description": "Lecture, seminar, lab or exam dates, times and locations, timetable clashes and requests to change teaching groups. Route technical access failures to IT Support."},
            {"name": "IT Support", "description": "University account access, passwords, MFA, Wi-Fi, email, learning platforms, software and technical portal failures, even when the affected portal is for another team."},
            {"name": "Wellbeing", "description": "Requests for counselling, emotional support, managing stress, settling in or finding student wellbeing services. Route requests specifically for financial assistance to Fees & Funding; do not infer a diagnosis or urgency."},
            {"name": "Other", "description": "Library services, societies, careers, general campus information, enquiries outside the listed teams or messages with too little detail to route."},
        ],
    },
    "symptoms": {
        "name": "Mild illness symptom examples (fictional)",
        "description": "Classify fictional symptom descriptions for a demo, not diagnosis or triage. Symptoms overlap and do not establish an illness or its severity; seek professional advice for real health concerns.",
        "data_file": DATA_DIR / "symptoms" / "data.config",
        "labels": [
            {"name": "Common Cold-like Symptoms", "description": "Fictional pattern of a runny or blocked nose, sneezing, scratchy throat and mild cough developing over a few days; not a diagnosis."},
            {"name": "Seasonal Allergy-like Symptoms", "description": "Fictional pattern of itchy or watery eyes, sneezing and clear nasal discharge associated with pollen or seasonal outdoor exposure; not a diagnosis."},
            {"name": "Tension Headache-like Symptoms", "description": "Fictional pattern of mild pressure or a tight band around the head after desk work, stress or neck tension; not a diagnosis."},
            {"name": "Indigestion-like Symptoms", "description": "Fictional pattern of fullness, bloating, belching or upper-abdominal discomfort after a large or rich meal; not a diagnosis."},
            {"name": "Motion Sickness-like Symptoms", "description": "Fictional pattern of nausea or queasiness during car, boat or bus travel, especially while reading, which eases when motion stops; not a diagnosis."},
            {"name": "Unclear / Insufficient Information", "description": "Too little detail, overlapping patterns or symptoms outside the listed examples. Do not infer a diagnosis or assume symptoms are harmless."},
        ],
    },
    "incidents": {
        "name": "Police incident log categories (fictional)",
        "description": "Categorise fictional incident reports by what is described, not a finding of guilt or a legal determination. Offence definitions vary by jurisdiction; ambiguous reports need human review.",
        "data_file": DATA_DIR / "incidents" / "data.config",
        "labels": [
            {"name": "Theft", "description": "Reported taking of property without permission, such as shoplifting or a stolen bicycle, without entry into a building or deceptive payment claims."},
            {"name": "Burglary", "description": "Reported unauthorised entry into a building or enclosed premises to steal, including attempted entry with stated intent to steal. Use this rather than Theft when both entry and taking are described."},
            {"name": "Criminal Damage", "description": "Reported deliberate damage to property, such as graffiti, vandalism or a smashed window, without stated intent to enter and steal."},
            {"name": "Fraud", "description": "Reported deception to obtain money or property, such as impersonation, false invoices or payments for deliberately misrepresented goods."},
            {"name": "Public Disorder", "description": "Reported threatening or abusive conduct or disruptive confrontation in a public place. Ordinary disagreement or a noise complaint alone is insufficient."},
            {"name": "Unclear / Insufficient Information", "description": "Missing facts, uncertain loss, accidental damage, non-crime reports or incidents outside the listed categories. Do not infer criminal intent or guilt."},
        ],
    },
}


def load_data(path):
    """Read a data.config file: one item per line; blank lines and lines starting with '#' are ignored."""
    items = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                items.append(line)
    return items
