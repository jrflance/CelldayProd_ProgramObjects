--liquibase formatted sql

--changeset Sammer Bazerbashi:0D55AB stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
-- noqa: disable=all
/*******************************************************************
	Author:         Samer Bazerbashi
	Version:
					1.0 2015-06-02 Used [Report].[P_Report_Trac_Data_Feed_All_Carriers_By_Unique_Address] as the basis of this report and added all the new
					requirements on top of it
					1.1 2015-06-12 Added filter to remove any RTR ith no RTR_TXN_REFERENCE1.  This indicates a non simple mobile vendor.
					2.0 removed join on act=batc_txt, added batch_txt restriction for vendor 33550, joined on Tracfone.tbltracfoneproduct to get product list
					2.1 2015-06-23 changed insert into celldaytemp.dbo.tmptracfone
					2.2 2015-06-24 changed insert into celldaytemp.Tracfone.tblTSPTransactionFeed
					2.3 2015-06-25 added voided activations joined with order_activation_user_lock
					2.4 2015-06-29 moved AND LEN(psn.Batch_txt) > 6 to join so that RTR don't get removed
					2.5 2015-06-30 split Net10 family plan into single skus
					3.0 2015-07-30 added pending activations so orders that start in day one and aren't completed until day two will get reported...we encountered
									problems with Tracfone being unable to pay the spiff if the pin doesn't exist in the file on the day before the redemption.  This will result
									in reporting the pins twice.
					4.0 2015-11-16 RTRs were not being submitted because the batchtxt criteria wasn't provided as a string
					4.1 2016-01-14 Added case to handle different addon values for RTR phone_number: instead of just phone number:.
					5.0 2016-01-22 Added new RTR activation reporting specs.  If vendor is TracSimple activation then reporting for o1.sku goes to RTR_REFERENCE1 instead of TXN_REFERENCE1.
					6.0 Added RTR vendor reporting
					7.0 2016-02-29 Added Marketplace subsidy in Attribute 1 field based on SMSNE flag and handset flag
					8.0 2016-03-30 Added Tracfone OrderID to Attribut 2 field.
					8.1 2016-04-27 Trac requested it to be Attribute 3 instead.
					9.0 2016-09-29 Changed the reporting to use our RTR SKU. Tracfone can now accept it for payments.
				   10.0 2016-10-19 Added a case for RTR activations that are manually processed to have pin show up in the SKU column rather than the default RTR_TXN_REFERENCE
				   11.0 2017-01-04 Only reporting Istracfone =1 accounts
				   12.0 2017-04-11 Added update to vendor dll name to have *
				   13.0 2017-10-17 AB Added Check to Make sure order carrier and SerialNumber_txt carrier are the same
				   14.0 2018-01-10 SB Added logic to check if the transaction is through the new Simple API to bring in the billitemnumber from the addons table
				   14.1 2018-01-23 AB added billitemnumber is numeric, not 0, not blank, and is not null to tblOrderItemAddons join
				   15.0 2018-06-08 SB added update to attribute_3 to remove ::% from the bulk submissions for DAP txn ID
				   16.0 2018-09-27 AB Added Activation Promo info to attribute 4 and 5
				   17.0 2018-10-16 SB Added single order insert capability into the feed
				   18.0 2019-01-14 AB Added case statement for [ATTRIBUTE_4] to send description
				   19.0 2019-01-16 AB Updated Cast of ATTRIBUTE_4 and ATTRIBUTE_5
				   20.0 2019-12-06 BS (SB reviewed) Used IDs from promo orders instead of original orders to get promos.  Added distinct to all final inserts or selects to manage issues with duplicate records
				   21.0 2019-12-26 CH (add index IX_OrderManagmenttblProviderReference_OrderNo and Option Recompile)
				   22.0 2020-02-17 SB Added CStore and Rural logic to filter data
				   22.1 2020-02-24 KMH Added '' around zip code to prevent nvarchar conversion error
				   23.0 2020-06-04 SB Added distinct to insert for @runinsert = 2 count check
				   24.0 2020-09-30 SB Added Amazon cash qualified promo activation orders in Attribute 1 for reimbursement
				   25.0 2021-03-19 SB Added TW handling for additional lines
				   26.0 2023-05-03 SB Added manually created promo support (created today but activation is in the past)
				   27.0 2023-05-09 SB Added session IDs to Attribute 2
				   28.0 2023-07-27 SB Removed old promo reporting and switched to amount from promo order
				   29.0 2023-08-02 SB IMEI added to SIM field for activations
				   30.0 2023-09-07 SB Added support for EsimNumberType
				   31.0 2023-10-02 SB Added VZW RTR, Pin, and Sim
				   32.0 2023-10-17 SB Add pending rebates
				   33.0 2024-02-23 SB Activation fee in Attribute 1
				   34.0 2024-03-07 SB Price - discount added to activation fee logic to handle 100% discount
	Reason:         New Tracfone reporting to be used 6/2015 for a daily feed.  All pins and RTRs for all accounts to be reported.
	Sample call:    EXEC [Report].[P_Report_TSP_Transaction_Feed] NULL (to be used for ssrs)
					EXEC [Report].[P_Report_TSP_Transaction_Feed] '2015-06-22',1  (to be used in SQL or the report menu)
	Frequency:      High

	*********************************************************************/
-- noqa: enable=all
-- noqa: disable=all
CREATE   PROC [Report].[P_Report_TSP_Transaction_Feed]
    (
        @Date DATETIME,
        @RunInsert TINYINT,
        @order_no INT,
        @sessionid INT
    )
AS
BEGIN
    BEGIN TRY
        SET NOCOUNT ON;

        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        IF (ISNULL(@sessionid, 0) <> 2)
            BEGIN
                SELECT 'You are not allowed to use this report' AS Error;
                RETURN;
            END



        IF @RunInsert = 2
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM Order_No WHERE Order_No = @order_no)
                    BEGIN
                        SELECT 'Please enter a valid order number.' AS Error;
                        RETURN;
                    END;
                ELSE
                IF
                    EXISTS
                    (
                        SELECT DISTINCT
                            a.Test
                        FROM
                            (
                                SELECT 1 AS Test
                                FROM Tracfone.tblTSPTransactionFeed
                                WHERE
                                    Order_No = @order_no
                                    AND RTR_TXN_REFERENCE1 IN
                                    (
                                        SELECT AddonsValue
                                        FROM dbo.tblOrderItemAddons
                                        WHERE
                                            AddonsID = 196
                                            AND OrderID IN
                                            (
                                                SELECT ID FROM Orders WHERE Order_No = @order_no AND ParentItemID = 0
                                            )
                                    )
                                UNION
                                SELECT 1 AS Test
                                FROM Tracfone.tblTSPTransactionFeed
                                WHERE
                                    Order_No = @order_no
                                    AND TXN_PIN IN
                                    (
                                        SELECT AddonsValue
                                        FROM dbo.tblOrderItemAddons
                                        WHERE
                                            AddonsID = 196
                                            AND OrderID IN
                                            (
                                                SELECT ID FROM Orders WHERE Order_No = @order_no AND ParentItemID = 0
                                            )
                                    )
                            ) AS a
                    )
                    BEGIN
                        SELECT 'Order and SKU have already been inserted.' AS Error;
                        RETURN;
                    END
            END

        IF @RunInsert = 2
            BEGIN
                SET
                    @Date =
                    (
                        SELECT DateFilled FROM Order_No WHERE Order_No = @order_no
                    );
            END;

        ELSE
            BEGIN
                IF @Date IS NULL
                    SET @Date = DATEADD(DAY, -1, GETDATE());
            END;

        DECLARE @DateCast DATE = NULL;

        SET @DateCast = CAST(@Date AS DATE);



        IF OBJECT_ID('tempdb..#orders') IS NOT NULL
            BEGIN
                DROP TABLE #orders;
            END;
        CREATE TABLE #orders
        (
            Datefilled DATETIME,
            Account_ID INT,
            Order_no INT,
            User_id INT,
            Choice TINYINT,
            TWSKU VARCHAR(30)
        );



        IF OBJECT_ID('tempdb..#TracfoneAirtimeProductIDs') IS NOT NULL
            BEGIN
                DROP TABLE #TracfoneAirtimeProductIDs;
            END;
        SELECT
            tpid.TracfoneProductID AS Product_ID,
            pc.Category_ID
        INTO #TracfoneAirtimeProductIDs
        FROM dbo.Product_Category AS pc WITH (READUNCOMMITTED)
        JOIN Tracfone.tblTracfoneProduct AS tpid
            ON tpid.TracfoneProductID = pc.Product_ID;

        IF OBJECT_ID('tempdb..#VZWAirtimeProductIDs') IS NOT NULL
            BEGIN
                DROP TABLE #VZWAirtimeProductIDs;
            END
        SELECT
            p.Product_ID AS Product_ID,
            pc.Category_ID
        INTO #VZWAirtimeProductIDs
        FROM dbo.Carrier_ID AS cid
        JOIN Products.tblProductCarrierMapping AS pcm
            ON pcm.CarrierId = cid.ID
        JOIN dbo.Products AS p
            ON p.Product_ID = pcm.ProductId
        JOIN dbo.Product_Category AS pc
            ON pc.Product_ID = pcm.ProductId
        WHERE
            cid.ID = 7
            AND ISNULL(p.Product_Type, '0') IN (0, 1);



        IF ISNUMERIC(@order_no) = 1
            BEGIN
                INSERT INTO #orders
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    CASE
                        WHEN o.OrderType_ID IN ( 1, 9, 19, 43, 44)
                            THEN 1
                        WHEN o.OrderType_ID IN (22, 23)
                            THEN 2
                    END AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
                WHERE o.Order_No = @order_no
                UNION
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    2 AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
                WHERE o.Order_No = @order_no
                UNION
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    2 AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
                JOIN dbo.Order_Activation_User_Lock AS oaul WITH (READUNCOMMITTED)
                    ON oaul.Order_No = o.Order_No
                WHERE o.Order_No = @order_no
                GROUP BY
                    o.DateFilled,
                    o.Account_ID,
                    o.Order_No,
                    o.User_ID;
            END;


        IF ISNUMERIC(@order_no) != 1
            BEGIN

                INSERT INTO #orders
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    CASE
                        WHEN o.OrderType_ID IN (1, 9, 19, 43, 44)
                            THEN 1
                        WHEN o.OrderType_ID IN (22, 23)
                            THEN 2
                    END AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED) --, INDEX = Ix_OrderNo_DateFilled )
                WHERE
                    o.DateFilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast)
                    AND o.Process = 1
                    AND o.Filled = 1
                    AND o.Void = 0
                    AND o.OrderType_ID IN (1, 9, 19, 22, 23, 43, 44) --19 is to get cloned qiwi orders
                    AND o.Account_ID != 22972
                    AND
                    (
                        o.Order_No = @order_no
                        OR @order_no IS NULL
                    )
                UNION
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    2 AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED)
                WHERE
                    o.DateFilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast)
                    --not including filled in case an order goes over API and pin is used but order doesn't get filled,
                    --also no void = 1 because we need to catch manually failed order and have Trac check on the pin usage
                    AND o.Process = 0
                    AND o.Void = 0
                    AND o.Filled = 0
                    AND o.OrderType_ID IN (22, 23)
                    AND o.Account_ID != 22972
                UNION
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    2 AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED) --, INDEX = Ix_OrderNo_DateFilled ) )
                JOIN dbo.Order_Activation_User_Lock AS oaul WITH (READUNCOMMITTED)
                    ON oaul.Order_No = o.Order_No
                WHERE
                    o.DateFilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast)
                    --not including filled in case an order goes over API and pin is used but order doesn't get filled,
                    --also no void = 1 because we need to catch manually failed order and have Trac check on the pin usage
                    AND o.Void = 1
                    AND o.OrderType_ID IN (22, 23)
                    AND o.Account_ID != 22972
                GROUP BY
                    o.DateFilled,
                    o.Account_ID,
                    o.Order_No,
                    o.User_ID
                UNION
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    3 AS Choice,
                    '' AS TWSKU
                FROM dbo.Order_No AS o WITH (READUNCOMMITTED) --, INDEX = Ix_OrderNo_DateFilled ) )
                WHERE
                    o.DateFilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast)
                    AND o.OrderType_ID IN (21)
                    AND o.Account_ID != 22972
                GROUP BY
                    o.DateFilled,
                    o.Account_ID,
                    o.Order_No,
                    o.User_ID
                UNION
                SELECT
                    o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    4 Choice,
                    '' TWSKU
                FROM dbo.Order_No o WITH (READUNCOMMITTED) --, INDEX = Ix_OrderNo_DateFilled ) )
                WHERE o.DateFilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast)
                    AND o.OrderType_ID IN ( 48, 49, 57, 58 )
                    AND o.Account_ID != 22972
                GROUP BY o.DateFilled,
                        o.Account_ID,
                        o.Order_No,
                        o.User_ID
                UNION
                SELECT o.DateFilled,
                    CAST(o.Account_ID AS VARCHAR(10)) AS Account_ID,
                    o.Order_No,
                    o.User_ID,
                    2 Choice,
                    '' TWSKU
                FROM dbo.Order_No o WITH (READUNCOMMITTED) --, INDEX = Ix_OrderNo_DateFilled )
                    JOIN dbo.Order_No o2
                        ON o2.AuthNumber = o.Order_No
                    JOIN dbo.Orders o3
                        ON o3.Order_No = o2.Order_No
                        AND o3.ParentItemID = 0
                WHERE o2.DateFilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast)
                    AND o2.Process = 1
                    AND o2.Filled = 1
                    AND o2.Void = 0
                    AND o2.OrderType_ID IN ( 59, 60 )
                    AND o3.Product_ID = 6084
                    AND o.Account_ID != 22972
                    AND
                    (
                        o.Order_No = @order_no
                        OR @order_no IS NULL
                    )
                    AND o.DateFilled < CAST(@DateCast AS DATE)
                    AND o.Process IN (0, 1)
                    AND o.Filled IN (0, 1)
                    AND o.Void = 0
                    AND o.OrderType_ID IN (22, 23)
                    AND o.Account_ID != 22972
                    AND
                    (
                        o.Order_No = @order_no
                        OR @order_no IS NULL
                    )
                OPTION (RECOMPILE) --> V21.0 CH 20191226 use the best index at run time CH 20191226
                ;
            END;

        --remove TW Add a line
        DELETE o
        FROM #orders o
            JOIN Orders o1
                ON o1.Order_no = o.Order_no
                AND o1.Product_ID IN ( 8387 );

        --Airtime products need to be driven by addons
        IF OBJECT_ID('tempdb..#TracAirtimeOrders') IS NOT NULL
        BEGIN
            DROP TABLE #TracAirtimeOrders;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    ''
                WHEN ISNULL(p.Product_Type, 0) = 1 THEN
                    ''
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    o1.SKU
                ELSE
                    o1.SKU
            END TXN_REFERENCE1, --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    'RML'
                WHEN ISNULL(p.Product_Type, 0) = 1 THEN
                    'RTR'
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    'PIN'
                ELSE
                    'PIN'
            END Product_Type,
            CASE
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone_Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 14, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Enter Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(o1.Addons, 20, 10)
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    ''
            END [Min],
                                --o1.Addons,
            '' [Sim],
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    toia.AddonsValue
                WHEN ISNULL(p.Product_Type, 0) = 1 THEN
                    o1.SKU
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    ''
                ELSE
                    o1.SKU
            END RTR_TXN_REFERENCE1,
            CASE
                WHEN LEN(psn.Batch_txt) <= 6 THEN
                    ''
                ELSE
                    psn.Batch_txt
            END TXN_SNP,
            o.Order_no,
            CASE
                WHEN LEFT(RIGHT(tpr.ReferenceID, 2), 1) = ':' THEN
                    REPLACE(tpr.ReferenceID, RIGHT(tpr.ReferenceID, 3), '')
                ELSE
                    tpr.ReferenceID
            END Attribute_3
        INTO #TracAirtimeOrders
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #TracfoneAirtimeProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tpid.Category_ID = cat.Category_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND LEN(psn.Batch_txt) > 6 -- this is so we don't lose any RTR data
            LEFT JOIN OrderManagment.tblProviderReference tpr --WITH (INDEX = IX_OrderManagmenttblProviderReference_OrderNo)
                ON tpr.OrderNo = o.Order_no
            LEFT JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
                AND toia.AddonsID = 196
                AND ISNUMERIC(toia.AddonsValue) = 1
                AND ISNULL(toia.AddonsValue, '') NOT IN ( '', '0' )
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 1
            AND o.Account_ID != 22972
            AND p.Product_ID != 2190;


        --Airtime products need to be driven by addons
        IF OBJECT_ID('tempdb..#VZWAirtimeOrders') IS NOT NULL
        BEGIN
            DROP TABLE #VZWAirtimeOrders;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    ''
                WHEN ISNULL(p.Product_Type, 0) = 1 THEN
                    ''
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    o1.SKU
                ELSE
                    o1.SKU
            END TXN_REFERENCE1, --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    'VZWRML'
                WHEN ISNULL(p.Product_Type, 0) = 1 THEN
                    'VZWRTR'
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    'VZWPIN'
                ELSE
                    'VZWPIN'
            END Product_Type,
            CASE
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone_Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 14, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Enter Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(o1.Addons, 20, 10)
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    ''
            END [Min],
                                --o1.Addons,
            '' [Sim],
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    toia.AddonsValue
                WHEN ISNULL(p.Product_Type, 0) = 1 THEN
                    o1.SKU
                WHEN ISNULL(p.Product_Type, 0) != 1 THEN
                    ''
                ELSE
                    o1.SKU
            END RTR_TXN_REFERENCE1,
            CASE
                WHEN LEN(psn.Batch_txt) <= 6 THEN
                    ''
                ELSE
                    psn.Batch_txt
            END TXN_SNP,
            o.Order_no,
            CASE
                WHEN LEFT(RIGHT(tpr.ReferenceID, 2), 1) = ':' THEN
                    REPLACE(tpr.ReferenceID, RIGHT(tpr.ReferenceID, 3), '')
                ELSE
                    tpr.ReferenceID
            END Attribute_3
        INTO #VZWAirtimeOrders
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #VZWAirtimeProductIDs vzw
                ON vzw.Product_ID = o1.Product_ID
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON vzw.Category_ID = cat.Category_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND LEN(psn.Batch_txt) > 6 -- this is so we don't lose any RTR data
            LEFT JOIN OrderManagment.tblProviderReference tpr --WITH (INDEX = IX_OrderManagmenttblProviderReference_OrderNo)
                ON tpr.OrderNo = o.Order_no
            LEFT JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
                AND toia.AddonsID = 196
                AND ISNUMERIC(toia.AddonsValue) = 1
                AND ISNULL(toia.AddonsValue, '') NOT IN ( '', '0' )
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 1
            AND o.Account_ID != 22972
            AND p.Product_ID != 2190;






        IF OBJECT_ID('tempdb..#TracNet10Familyfirstpin') IS NOT NULL
        BEGIN
            DROP TABLE #TracNet10Familyfirstpin;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN p.Product_Type = 1 THEN
                    ''
                ELSE
                    SUBSTRING(o1.SKU, 1, 15)
            END TXN_REFERENCE1,
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'PIN' Product_Type,
            CASE
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone_Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Enter Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(o1.Addons, 20, 10)
                WHEN
                (
                    p.Product_Type IS NULL
                    OR p.Product_Type != 1
                ) THEN
                    ''
            END [Min],
            '' [Sim],
            '' RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            o.Order_no,
            tpr.ReferenceID Attribute_3
        INTO #TracNet10Familyfirstpin
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #TracfoneAirtimeProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tpid.Category_ID = cat.Category_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND LEN(psn.Batch_txt) > 6
            LEFT JOIN OrderManagment.tblProviderReference tpr
                ON tpr.OrderNo = o.Order_no
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 1
            AND o.Account_ID != 22972
            AND p.Product_ID IN ( 2190, 8312, 8314, 8316 );



        IF OBJECT_ID('tempdb..#TracNet10Family2ndpin') IS NOT NULL
        BEGIN
            DROP TABLE #TracNet10Family2ndpin;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN p.Product_Type = 1 THEN
                    ''
                ELSE
                    SUBSTRING(o1.SKU, 18, 15)
            END TXN_REFERENCE1,
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'PIN' Product_Type,
            CASE
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone_Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Enter Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(o1.Addons, 20, 10)
                WHEN
                (
                    p.Product_Type IS NULL
                    OR p.Product_Type != 1
                ) THEN
                    ''
            END [Min],
            '' [Sim],
            '' RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            o.Order_no,
            tpr.ReferenceID Attribute_3
        INTO #TracNet10Family2ndpin
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #TracfoneAirtimeProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tpid.Category_ID = cat.Category_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND LEN(psn.Batch_txt) > 6
            LEFT JOIN OrderManagment.tblProviderReference tpr
                ON tpr.OrderNo = o.Order_no
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 1
            AND o.Account_ID != 22972
            AND p.Product_ID IN ( 2190, 8312, 8314, 8316 );



        IF OBJECT_ID('tempdb..#TracNet10Family3rdpin') IS NOT NULL
        BEGIN
            DROP TABLE #TracNet10Family3rdpin;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN p.Product_Type = 1 THEN
                    ''
                ELSE
                    SUBSTRING(o1.SKU, 35, 15)
            END TXN_REFERENCE1,
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'PIN' Product_Type,
            CASE
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone_Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Enter Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(o1.Addons, 20, 10)
                WHEN
                (
                    p.Product_Type IS NULL
                    OR p.Product_Type != 1
                ) THEN
                    ''
            END [Min],
            '' [Sim],
            '' RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            o.Order_no,
            tpr.ReferenceID Attribute_3
        INTO #TracNet10Family3rdpin
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #TracfoneAirtimeProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tpid.Category_ID = cat.Category_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND LEN(psn.Batch_txt) > 6
            LEFT JOIN OrderManagment.tblProviderReference tpr
                ON tpr.OrderNo = o.Order_no
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 1
            AND o.Account_ID != 22972
            AND p.Product_ID IN ( 8314, 8316 );

        IF OBJECT_ID('tempdb..#TracNet10Family4thpin') IS NOT NULL
        BEGIN
            DROP TABLE #TracNet10Family4thpin;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN p.Product_Type = 1 THEN
                    ''
                ELSE
                    SUBSTRING(o1.SKU, 52, 15)
            END TXN_REFERENCE1,
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'PIN' Product_Type,
            CASE
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Phone_Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(REPLACE(CAST(o1.Addons AS VARCHAR(100)), ' ', ''), 13, 10)
                WHEN p.Product_Type = 1
                        AND PATINDEX('Enter Phone Number:%', o1.Addons) = 1 THEN
                    SUBSTRING(o1.Addons, 20, 10)
                WHEN
                (
                    p.Product_Type IS NULL
                    OR p.Product_Type != 1
                ) THEN
                    ''
            END [Min],
            '' [Sim],
            '' RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            o.Order_no,
            tpr.ReferenceID Attribute_3
        INTO #TracNet10Family4thpin
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #TracfoneAirtimeProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tpid.Category_ID = cat.Category_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND LEN(psn.Batch_txt) > 6
            LEFT JOIN OrderManagment.tblProviderReference tpr
                ON tpr.OrderNo = o.Order_no
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 1
            AND o.Account_ID != 22972
            AND p.Product_ID IN ( 8316 );









        IF OBJECT_ID('tempdb..#TracfoneActivationProductIDs') IS NOT NULL
        BEGIN
            DROP TABLE #TracfoneActivationProductIDs;
        END;
        SELECT tpid.TracfoneProductID AS Product_ID,
            pc.Category_ID
        INTO #TracfoneActivationProductIDs
        FROM dbo.Product_Category pc WITH (READUNCOMMITTED)
            JOIN Tracfone.tblTracfoneProduct tpid
                ON tpid.TracfoneProductID = pc.Product_ID;

        IF OBJECT_ID('tempdb..#tracactivationcatnames') IS NOT NULL
        BEGIN
            DROP TABLE #tracactivationcatnames;
        END;
        SELECT tapid.Product_ID,
            tapid.Category_ID,
            cat.Parent_ID,
            cat2.Name
        INTO #tracactivationcatnames
        FROM #TracfoneActivationProductIDs tapid
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tapid.Category_ID = cat.Category_ID
            JOIN dbo.Categories cat2 WITH (READUNCOMMITTED)
                ON cat.Parent_ID = cat2.Category_ID;


        IF OBJECT_ID('tempdb..#VZWActivationProductIDs') IS NOT NULL
        BEGIN
            DROP TABLE #VZWActivationProductIDs;
        END;

        SELECT p.Product_ID,
            pc.Category_ID
        INTO #VZWActivationProductIDs
        FROM dbo.Carrier_ID cid
            JOIN Products.tblProductCarrierMapping pcm
                ON pcm.CarrierId = cid.ID
            JOIN dbo.Products p
                ON p.Product_ID = pcm.ProductId
            JOIN dbo.Product_Category pc
                ON pc.Product_ID = p.Product_ID
        WHERE cid.ID = 7
            AND p.Product_Type IN ( 3 )
            AND p.Name NOT LIKE 'global%';


        IF OBJECT_ID('tempdb..#VZWactivationcatnames') IS NOT NULL
        BEGIN
            DROP TABLE #VZWactivationcatnames;
        END;
        SELECT tapid.Product_ID,
            tapid.Category_ID,
            cat.Parent_ID,
            cat2.Name
        INTO #VZWactivationcatnames
        FROM #VZWActivationProductIDs tapid
            JOIN dbo.Categories cat WITH (READUNCOMMITTED)
                ON tapid.Category_ID = cat.Category_ID
            JOIN dbo.Categories cat2 WITH (READUNCOMMITTED)
                ON cat.Parent_ID = cat2.Category_ID;



        INSERT INTO #orders
        (
            Datefilled,
            Account_ID,
            Order_no,
            User_id,
            Choice,
            TWSKU
        )
        SELECT A.Datefilled,
            A.Account_ID,
            A.Order_no,
            A.User_id,
            A.Choice,
            CONCAT(A.SKU, '-', A.RNum) TWSKU
        FROM
        (
            SELECT DISTINCT
                o3.Datefilled,
                o3.Account_ID,
                o3.Order_no,
                o3.User_id,
                2 Choice,
                toia.AddonsValue SKU,
                ROW_NUMBER() OVER (PARTITION BY o2.SKU ORDER BY o2.SKU, o3.Order_no) RNum
            FROM #orders f
                JOIN dbo.Order_No o
                    ON o.Order_no = f.Order_no
                    AND f.Choice = 2
                JOIN dbo.Orders o1
                    ON o1.Order_no = o.Order_no
                    AND o1.ParentItemID = 0
                    AND o1.Product_ID IN ( 9233, 9232, 9231, 8269, 8270, 8271 )
                JOIN dbo.tblOrderItemAddons toia
                    ON toia.OrderID = o1.ID
                    AND toia.AddonsID = 196
                JOIN dbo.Orders o2
                    ON o2.SKU = o1.SKU
                    AND o2.Product_ID = 8387
                JOIN dbo.Order_No o3
                    ON o3.Order_no = o2.Order_no
                    AND o3.Datefilled
                    BETWEEN @DateCast AND DATEADD(DAY, 1, @DateCast) -- '2021-03-18' AND '2021-03-19'

        ) A;



        IF OBJECT_ID('tempdb..#TracActivationOrders') IS NOT NULL
        BEGIN
            DROP TABLE #TracActivationOrders;
        END;
        SELECT DISTINCT
            o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    ''
                WHEN EXISTS --2017-01-09 SB All airtime RTRs are in the serial table, no activation RTRs are in the serial table
                        ( --2018-01-17 SB Discussed with Jacob and Angela about any potential efficiency advantages.  We agreed that efficiency via statistics has been met and uniform cases and readability were more important for TXN_Reference1, Product Type, and RTR_TXN_Reference1 columns
                            SELECT 1
                            FROM dbo.Product_SerialNum psn
                                JOIN Products.tblProductCarrierMapping pcm
                                    ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                JOIN Products.tblProductCarrierMapping pcm1
                                    ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                    AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                            WHERE SerialNumber_txt = o1.SKU
                        ) THEN
                    o1.SKU
                WHEN EXISTS
                        (
                            SELECT 1 FROM dbo.Order_Activation_User_Lock WHERE Order_no = o.Order_no
                        ) THEN
                    o1.SKU
                WHEN NOT EXISTS --2017-01-09 SB All airtime RTRs are in the serial table, no activation RTRs are in the serial table
                            (
                                SELECT 1
                                FROM dbo.Product_SerialNum psn
                                    JOIN Products.tblProductCarrierMapping pcm
                                        ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                    JOIN Products.tblProductCarrierMapping pcm1
                                        ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                        AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                                WHERE SerialNumber_txt = o1.SKU
                            ) THEN
                    ''
            END TXN_REFERENCE1,
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    'RML'
                WHEN NOT EXISTS
                            (
                                SELECT 1
                                FROM dbo.Product_SerialNum psn
                                    JOIN Products.tblProductCarrierMapping pcm
                                        ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                    JOIN Products.tblProductCarrierMapping pcm1
                                        ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                        AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                                WHERE SerialNumber_txt = o1.SKU
                            ) THEN
                    'RTR'
                WHEN EXISTS
                        (
                            SELECT 1 FROM dbo.Order_Activation_User_Lock WHERE Order_no = o.Order_no
                        ) THEN
                    'PIN'
                ELSE
                    'PIN'
            END Product_Type,
            CAST(toia2.AddonsValue AS NVARCHAR(200)) AS Sim, -- Fix for INC-468986 30-03-2021
            CASE
                WHEN o1.Product_ID = 8387 THEN
                    o.TWSKU
                WHEN toia.OrderID = o1.ID THEN
                    toia.AddonsValue
                WHEN NOT EXISTS
                            (
                                SELECT 1
                                FROM dbo.Product_SerialNum psn
                                    JOIN Products.tblProductCarrierMapping pcm
                                        ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                    JOIN Products.tblProductCarrierMapping pcm1
                                        ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                        AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                                WHERE SerialNumber_txt = o1.SKU
                            ) THEN
                    o1.SKU
                WHEN EXISTS
                        (
                            SELECT 1 FROM dbo.Order_Activation_User_Lock WHERE Order_no = o.Order_no
                        ) THEN
                    ''
                WHEN EXISTS --2017-01-09 SB All airtime RTRs are in the serial table, no activation RTRs are in the serial table
                        (
                            SELECT 1
                            FROM dbo.Product_SerialNum psn
                                JOIN Products.tblProductCarrierMapping pcm
                                    ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                JOIN Products.tblProductCarrierMapping pcm1
                                    ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                    AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                            WHERE SerialNumber_txt = o1.SKU
                        ) THEN
                    ''
            END RTR_TXN_REFERENCE1,
            '' AS [MIN],
            CASE
                WHEN LEN(psn.Batch_txt) <= 6
                        OR psn.Batch_txt IS NULL THEN
                    ''
                ELSE
                    psn.Batch_txt
            END TXN_SNP,
            o.Order_no,
            CASE
                WHEN LEFT(RIGHT(tpr.ReferenceID, 2), 1) = ':' THEN
                    REPLACE(tpr.ReferenceID, RIGHT(tpr.ReferenceID, 3), '')
                ELSE
                    tpr.ReferenceID
            END Attribute_3
        INTO #TracActivationOrders
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #TracfoneActivationProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN #tracactivationcatnames cat WITH (READUNCOMMITTED)
                ON cat.Product_ID = o1.Product_ID
            LEFT JOIN Account.AccountCarrierTerms act WITH (READUNCOMMITTED)
                ON act.Account_ID = a.Account_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND o1.SKU IS NOT NULL
            LEFT JOIN OrderManagment.tblProviderReference tpr
                ON tpr.OrderNo = o.Order_no
            LEFT JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
                AND toia.AddonsID = 196
                AND ISNUMERIC(toia.AddonsValue) = 1
                AND ISNULL(toia.AddonsValue, '') NOT IN ( '', '0' )
            LEFT JOIN dbo.tblOrderItemAddons toia2
                ON toia2.OrderID = o1.ID
                AND toia2.AddonsID IN
                    (
                        SELECT taf.AddonID
                        FROM dbo.tblAddonFamily taf
                        WHERE taf.AddonTypeName IN ( 'Devicetype', 'devicebyoptype' )
                    )
                AND ISNUMERIC(toia2.AddonsValue) = 1
                AND ISNULL(toia2.AddonsValue, '') NOT IN ( '', '0' )
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 2
            AND o1.ParentItemID = 0
            AND o.Account_ID != 22972;

        UPDATE #TracActivationOrders
        SET Sim = toia2.AddonsValue
        FROM #TracActivationOrders t
            JOIN dbo.Order_No o
                ON o.Order_no = t.Order_no
            JOIN Orders o1
                ON o1.Order_no = o.Order_no
                AND o1.Product_ID IN ( 8387 )
            JOIN dbo.tblOrderItemAddons toia2
                ON toia2.OrderID = o1.ID
            JOIN dbo.tblAddonFamily taf
                ON taf.AddonID = toia2.AddonsID
                AND taf.AddonTypeName IN ( 'SimType', 'SimBYOPType', 'ESimNumberType' );





        IF OBJECT_ID('tempdb..#VZWActivationOrders') IS NOT NULL
        BEGIN
            DROP TABLE #VZWActivationOrders;
        END;
        SELECT DISTINCT
            o.Datefilled AS HOST_TIMESTAMP,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    ''
                WHEN EXISTS --2017-01-09 SB All airtime RTRs are in the serial table, no activation RTRs are in the serial table
                        ( --2018-01-17 SB Discussed with Jacob and Angela about any potential efficiency advantages.  We agreed that efficiency via statistics has been met and uniform cases and readability were more important for TXN_Reference1, Product Type, and RTR_TXN_Reference1 columns
                            SELECT 1
                            FROM dbo.Product_SerialNum psn
                                JOIN Products.tblProductCarrierMapping pcm
                                    ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                JOIN Products.tblProductCarrierMapping pcm1
                                    ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                    AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                            WHERE SerialNumber_txt = o1.SKU
                        ) THEN
                    o1.SKU
                WHEN EXISTS
                        (
                            SELECT 1 FROM dbo.Order_Activation_User_Lock WHERE Order_no = o.Order_no
                        ) THEN
                    o1.SKU
                WHEN NOT EXISTS --2017-01-09 SB All airtime RTRs are in the serial table, no activation RTRs are in the serial table
                            (
                                SELECT 1
                                FROM dbo.Product_SerialNum psn
                                    JOIN Products.tblProductCarrierMapping pcm
                                        ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                    JOIN Products.tblProductCarrierMapping pcm1
                                        ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                        AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                                WHERE SerialNumber_txt = o1.SKU
                            ) THEN
                    ''
            END TXN_REFERENCE1,
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cat.Name AS Product_Supplier,
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            CASE
                WHEN toia.OrderID = o1.ID THEN
                    'VZWRML'
                WHEN NOT EXISTS
                            (
                                SELECT 1
                                FROM dbo.Product_SerialNum psn
                                    JOIN Products.tblProductCarrierMapping pcm
                                        ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                    JOIN Products.tblProductCarrierMapping pcm1
                                        ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                        AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                                WHERE SerialNumber_txt = o1.SKU
                            ) THEN
                    'VZWRTR'
                WHEN EXISTS
                        (
                            SELECT 1 FROM dbo.Order_Activation_User_Lock WHERE Order_no = o.Order_no
                        ) THEN
                    'VZWPIN'
                ELSE
                    'VZWPIN'
            END Product_Type,
            CAST(toia2.AddonsValue AS NVARCHAR(200)) AS Sim, -- Fix for INC-468986 30-03-2021
            CASE
                WHEN o1.Product_ID = 8387 THEN
                    o.TWSKU
                WHEN toia.OrderID = o1.ID THEN
                    toia.AddonsValue
                WHEN NOT EXISTS
                            (
                                SELECT 1
                                FROM dbo.Product_SerialNum psn
                                    JOIN Products.tblProductCarrierMapping pcm
                                        ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                    JOIN Products.tblProductCarrierMapping pcm1
                                        ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                        AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                                WHERE SerialNumber_txt = o1.SKU
                            ) THEN
                    o1.SKU
                WHEN EXISTS
                        (
                            SELECT 1 FROM dbo.Order_Activation_User_Lock WHERE Order_no = o.Order_no
                        ) THEN
                    ''
                WHEN EXISTS --2017-01-09 SB All airtime RTRs are in the serial table, no activation RTRs are in the serial table
                        (
                            SELECT 1
                            FROM dbo.Product_SerialNum psn
                                JOIN Products.tblProductCarrierMapping pcm
                                    ON psn.Product_ID = pcm.ProductId -- Get SerialNumber_txt carrier
                                JOIN Products.tblProductCarrierMapping pcm1
                                    ON o1.Product_ID = pcm1.ProductId --Get order carrier
                                    AND pcm.CarrierId = pcm1.CarrierId --Make sure order carrier and SerialNumber_txt carrier are the same
                            WHERE SerialNumber_txt = o1.SKU
                        ) THEN
                    ''
            END RTR_TXN_REFERENCE1,
            '' AS [MIN],
            CASE
                WHEN LEN(psn.Batch_txt) <= 6
                        OR psn.Batch_txt IS NULL THEN
                    ''
                ELSE
                    psn.Batch_txt
            END TXN_SNP,
            o.Order_no,
            CASE
                WHEN LEFT(RIGHT(tpr.ReferenceID, 2), 1) = ':' THEN
                    REPLACE(tpr.ReferenceID, RIGHT(tpr.ReferenceID, 3), '')
                ELSE
                    tpr.ReferenceID
            END Attribute_3
        INTO #VZWActivationOrders
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN #VZWActivationProductIDs tpid
                ON tpid.Product_ID = o1.Product_ID
            JOIN #VZWactivationcatnames cat WITH (READUNCOMMITTED)
                ON cat.Product_ID = o1.Product_ID
            LEFT JOIN Account.AccountCarrierTerms act WITH (READUNCOMMITTED)
                ON act.Account_ID = a.Account_ID
            LEFT JOIN dbo.Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
            LEFT JOIN dbo.Product_SerialNum psn WITH (READUNCOMMITTED)
                ON o1.SKU = psn.SerialNumber_txt
                AND o1.SKU IS NOT NULL
            LEFT JOIN OrderManagment.tblProviderReference tpr
                ON tpr.OrderNo = o.Order_no
            LEFT JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
                AND toia.AddonsID = 196
                AND ISNUMERIC(toia.AddonsValue) = 1
                AND ISNULL(toia.AddonsValue, '') NOT IN ( '', '0' )
            LEFT JOIN dbo.tblOrderItemAddons toia2
                ON toia2.OrderID = o1.ID
                AND toia2.AddonsID IN
                    (
                        SELECT taf.AddonID
                        FROM dbo.tblAddonFamily taf
                        WHERE taf.AddonTypeName IN ( 'Devicetype', 'devicebyoptype' )
                    )
                AND ISNUMERIC(toia2.AddonsValue) = 1
                AND ISNULL(toia2.AddonsValue, '') NOT IN ( '', '0' )
        WHERE o1.SKU IS NOT NULL
            AND o.Choice = 2
            AND o1.ParentItemID = 0
            AND o.Account_ID != 22972;



        IF OBJECT_ID('tempdb..#TracSim') IS NOT NULL
        BEGIN
            DROP TABLE #TracSim;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            '' TXN_REFERENCE1,                    --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cid.Carrier_Name AS Product_Supplier, --??? for device or for sim?
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'SIM' Product_Type,
            '' [MIN],
            CAST(o1.SKU AS NVARCHAR(200)) [Sim],
            CAST(o1.ID AS VARCHAR(30)) RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            CAST(o.Order_no AS VARCHAR(30)) Order_no,
            CAST('' AS NVARCHAR(10)) Attribute_3,
            CAST('' AS NVARCHAR(10)) Attribute_4, --migration campaign name or other promo name -- Not going to know this
            CAST('0' AS NVARCHAR(10)) Attribute_5 --instant credit dollar amount (i.e. "9" or "0")
        INTO #TracSim
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
                AND p.SubProductTypeId = 5 --marketplace sim from the sim assignment order
            JOIN Products.tblProductCarrierMapping pcm
                ON pcm.ProductId = o1.Product_ID
            JOIN dbo.Carrier_ID cid
                ON cid.ID = pcm.CarrierId
                AND cid.ParentCompanyId = 1
        WHERE o.Choice = 3
        UNION
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            '' TXN_REFERENCE1,                                           --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cid.Carrier_Name AS Product_Supplier,                        --??? for device or for sim?
            '0' AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'SIM' Product_Type,
            '' [MIN],
            CAST(toia.AddonsValue AS NVARCHAR(200)) [Sim],
            CAST(o1.ID AS VARCHAR(30)) RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            CAST(o.Order_no AS VARCHAR(30)) Order_no,
            CAST('' AS NVARCHAR(10)) Attribute_3,
            CAST('' AS NVARCHAR(10)) Attribute_4,                        --migration campaign name or other promo name -- Not going to know this
            CAST((ISNULL(o2.Price, 0)) * -1 AS NVARCHAR(10)) Attribute_5 --instant credit dollar amount (i.e. "9" or "0")
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            JOIN Orders o2
                ON o2.Order_no = o.Order_no
                AND o2.ParentItemID != 0
            JOIN dbo.Products p
                ON p.Product_ID = o1.Product_ID
                AND p.SubProductTypeId = 16
            JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
            JOIN dbo.tblAddonFamily taf
                ON taf.AddonID = toia.AddonsID
                AND taf.AddonTypeName IN ( 'SimType', 'SimBYOPType', 'ESimNumberType' )
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN Products.tblProductCarrierMapping pcm
                ON pcm.ProductId = o1.Product_ID
            JOIN dbo.Carrier_ID cid
                ON cid.ID = pcm.CarrierId
                AND cid.ParentCompanyId = 1
        WHERE o.Choice = 2
        UNION
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            '' TXN_REFERENCE1,                                           --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cid.Carrier_Name AS Product_Supplier,                        --??? for device or for sim?
            '0' AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'SIM' Product_Type,
            '' [MIN],
            CAST(toia.AddonsValue AS NVARCHAR(200)) [Sim],
            CAST(o1.ID AS VARCHAR(30)) RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            CAST(o.Order_no AS VARCHAR(30)) Order_no,
            CAST('' AS NVARCHAR(10)) Attribute_3,
            CAST('' AS NVARCHAR(10)) Attribute_4,                        --migration campaign name or other promo name -- Not going to know this
            CAST((ISNULL(o2.Price, 0)) * -1 AS NVARCHAR(10)) Attribute_5 --instant credit dollar amount (i.e. "9" or "0")
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            JOIN Orders o2
                ON o2.Order_no = o.Order_no
                AND o2.ParentItemID != 0
            JOIN dbo.Products p
                ON p.Product_ID = o1.Product_ID
                AND p.SubProductTypeId IN ( 2, 3, 5 )
            JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN Products.tblProductCarrierMapping pcm
                ON pcm.ProductId = o1.Product_ID
            JOIN dbo.Carrier_ID cid
                ON cid.ID = pcm.CarrierId
                AND cid.ParentCompanyId = 1
        WHERE o.Choice = 4;






        IF OBJECT_ID('tempdb..#VZWSim') IS NOT NULL
        BEGIN
            DROP TABLE #VZWSim;
        END;
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            '' TXN_REFERENCE1,                    --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cid.Carrier_Name AS Product_Supplier, --??? for device or for sim?
            o1.Price AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'VZWSIM' Product_Type,
            '' [MIN],
            CAST(o1.SKU AS NVARCHAR(200)) [Sim],
            CAST(o1.ID AS VARCHAR(30)) RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            CAST(o.Order_no AS VARCHAR(30)) Order_no,
            CAST('' AS NVARCHAR(10)) Attribute_3,
            CAST('' AS NVARCHAR(10)) Attribute_4, --migration campaign name or other promo name -- Not going to know this
            CAST('0' AS NVARCHAR(10)) Attribute_5 --instant credit dollar amount (i.e. "9" or "0")
        INTO #VZWSim
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN Products p WITH (READUNCOMMITTED)
                ON p.Product_ID = o1.Product_ID
                AND p.SubProductTypeId = 5 --marketplace sim from the sim assignment order
            JOIN Products.tblProductCarrierMapping pcm
                ON pcm.ProductId = o1.Product_ID
            JOIN dbo.Carrier_ID cid
                ON cid.ID = pcm.CarrierId
                AND cid.ParentCompanyId = 5
        WHERE o.Choice = 3
        UNION
        SELECT o.Datefilled AS HOST_TIMESTAMP,
            '' TXN_REFERENCE1,                                           --This is the pin column and needs to be changed to bring from
            o1.Name AS PRODUCT_NAME,
            o1.Product_ID AS PRODUCT_SKU,
            cid.Carrier_Name AS Product_Supplier,                        --??? for device or for sim?
            '0' AS VALUE,
            CAST(a.Account_ID AS VARCHAR(10)) AS TERMINAL_ID,
            a.Account_Name AS RETAILER_NAME,
            c.Address1,
            c.Address2,
            c.City,
            c.State,
            c.Zip,
            c.Phone AS PHONE_NUMBER,
            'VZWSIM' Product_Type,
            '' [MIN],
            CAST(toia.AddonsValue AS NVARCHAR(200)) [Sim],
            CAST(o1.ID AS VARCHAR(30)) RTR_TXN_REFERENCE1,
            '' TXN_SNP,
            CAST(o.Order_no AS VARCHAR(30)) Order_no,
            CAST('' AS NVARCHAR(10)) Attribute_3,
            CAST('' AS NVARCHAR(10)) Attribute_4,                        --migration campaign name or other promo name -- Not going to know this
            CAST((ISNULL(o2.Price, 0)) * -1 AS NVARCHAR(10)) Attribute_5 --instant credit dollar amount (i.e. "9" or "0")
        FROM #orders o
            JOIN dbo.Orders o1 WITH (READUNCOMMITTED)
                ON o.Order_no = o1.Order_no
            JOIN Orders o2
                ON o2.Order_no = o.Order_no
                AND o2.ParentItemID != 0
            JOIN dbo.Products p
                ON p.Product_ID = o1.Product_ID
                AND p.SubProductTypeId = 16
            JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
            JOIN dbo.tblAddonFamily taf
                ON taf.AddonID = toia.AddonsID
                AND taf.AddonTypeName IN ( 'SimType', 'SimBYOPType', 'ESimNumberType' )
            LEFT JOIN dbo.Account a WITH (READUNCOMMITTED)
                ON o.Account_ID = a.Account_ID
            LEFT JOIN dbo.Customers c WITH (READUNCOMMITTED)
                ON c.Customer_ID = a.Customer_ID
            JOIN Products.tblProductCarrierMapping pcm
                ON pcm.ProductId = o1.Product_ID
            JOIN dbo.Carrier_ID cid
                ON cid.ID = pcm.CarrierId
                AND cid.ParentCompanyId = 5
        WHERE o.Choice = 2;




        IF OBJECT_ID('tempdb..#finallookupBeforePromos') IS NOT NULL
        BEGIN
            DROP TABLE #finallookupBeforePromos;
        END;
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            Min,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        INTO #finallookupBeforePromos
        FROM #TracAirtimeOrders tato
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            Min,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #VZWAirtimeOrders tato
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            MIN,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            '' AS Attribute_3,
            Attribute_4,
            Attribute_5,
            ts.Order_no
        FROM #TracSim ts
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            MIN,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            '' AS Attribute_3,
            Attribute_4,
            Attribute_5,
            ts.Order_no
        FROM #VZWSim ts
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            MIN,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            tato.City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            CASE
                WHEN ISNULL(toia2.AddonsValue, '') = '' THEN
                    toia.AddonsValue
                ELSE
                    toia2.AddonsValue
            END AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #TracActivationOrders tato
            LEFT JOIN Phone_Active_Kit pak
                ON pak.Order_no = tato.Order_no
            LEFT JOIN Account.AccountCarrierTerms act
                ON tato.TERMINAL_ID = act.Account_ID
            LEFT JOIN Orders o1
                ON o1.Order_no = tato.Order_no
                AND o1.ParentItemID = 0
            LEFT JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
                AND toia.AddonsID = 358
            LEFT JOIN dbo.tblOrderItemAddons toia2
                ON toia2.OrderID = o1.ID
                AND toia.AddonsID = 359
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            MIN,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            tato.City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            CASE
                WHEN ISNULL(toia2.AddonsValue, '') = '' THEN
                    toia.AddonsValue
                ELSE
                    toia2.AddonsValue
            END AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #VZWActivationOrders tato
            LEFT JOIN Phone_Active_Kit pak
                ON pak.Order_no = tato.Order_no
            LEFT JOIN Account.AccountCarrierTerms act
                ON tato.TERMINAL_ID = act.Account_ID
            LEFT JOIN Orders o1
                ON o1.Order_no = tato.Order_no
                AND o1.ParentItemID = 0
            LEFT JOIN dbo.tblOrderItemAddons toia
                ON toia.OrderID = o1.ID
                AND toia.AddonsID = 358
            LEFT JOIN dbo.tblOrderItemAddons toia2
                ON toia2.OrderID = o1.ID
                AND toia.AddonsID = 359
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            Min,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #TracNet10Familyfirstpin tato
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            Min,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #TracNet10Family2ndpin tato
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            Min,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #TracNet10Family3rdpin tato
        UNION
        SELECT DISTINCT
            HOST_TIMESTAMP,
            Product_Type TXN_GROUP,
            Sim,
            Min,
            RTR_TXN_REFERENCE1,
            TXN_REFERENCE1 AS TXN_PIN,
            TXN_SNP,
            PRODUCT_NAME,
            PRODUCT_SKU,
            Product_Supplier,
            VALUE,
            CASE
                WHEN VALUE >= 0 THEN
                    'DEB'
                WHEN VALUE < 0 THEN
                    'CRE'
            END TXN_TYPE,
            TERMINAL_ID AS TSP_ID,
            RETAILER_NAME AS DEALER_NAME,
            Address1,
            Address2,
            City,
            State,
            Zip,
            REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''), ')', '') AS PHONE_NUMBER,
            '' AS ATTRIBUTE_1,
            '' AS ATTRIBUTE_2,
            Attribute_3,
            '' AS ATTRIBUTE_4,
            '' AS ATTRIBUTE_5,
            tato.Order_no
        FROM #TracNet10Family4thpin tato
        ORDER BY HOST_TIMESTAMP ASC;



        IF OBJECT_ID('tempdb..#CheckForPromos') IS NOT NULL
        BEGIN
            DROP TABLE #CheckForPromos;
        END;
        SELECT DISTINCT
            o.ID,
            ttf.Order_no,
            n.OrderType_ID,
            ttf.RTR_TXN_REFERENCE1,
            ttf.TXN_PIN --, ttf.TSPTransactionFeedID, ttf.TXN_GROUP
        INTO #CheckForPromos
        FROM #finallookupBeforePromos ttf
            JOIN dbo.Order_No n
                ON n.Order_no = ttf.Order_no
                AND n.OrderType_ID IN ( 22, 23, 1, 9 )
                AND n.Filled = 1
                AND n.Process = 1
                AND n.Void = 0
            JOIN dbo.Orders o
                ON n.Order_no = o.Order_no
                AND ISNULL(o.ParentItemID, 0) = 0;
        --  SELECT * FROM #CheckForPromos


        --activation
        IF OBJECT_ID('tempdb..#ActivationPromos') IS NOT NULL
        BEGIN
            DROP TABLE #ActivationPromos;
        END;
        SELECT DISTINCT
            n.ID,
            n.Order_no,
            p.Order_no AS [Promo_Order_No],
            o.ID AS [Promo_ID], --BS added IDs from promo orders
            p.OrderType_ID,
            n.RTR_TXN_REFERENCE1,
            n.TXN_PIN,
            o.Dropship_Qty,
            o.Price * -1 PromoAmount
        INTO #ActivationPromos
        FROM #CheckForPromos n
            JOIN dbo.Order_No p
                ON CAST(n.Order_no AS VARCHAR(15)) = p.AuthNumber
                AND p.OrderType_ID IN ( 59, 60 ) --Promo Order
                AND p.Filled IN ( 0, 1 )
                AND p.Process IN ( 0, 1 )
                AND p.Void = 0
            JOIN dbo.Orders o
                ON p.Order_no = o.Order_no
                AND o.Price < 0
        WHERE n.OrderType_ID IN ( 22, 23 )
            AND o.Product_ID = 6084;
        -- SELECT * FROM #ActivationPromos


        --Find datefilled of branded/marketplace order for each activation
        IF OBJECT_ID('tempdb..#POFilledA') IS NOT NULL
        BEGIN
            DROP TABLE #POFilledA;
        END;
        SELECT DISTINCT
            b.DateFilled AS [PODateFilled],
            ap.ID,
            oia.AddonsValue,
            pak.PONumber,
            o.Product_ID AS [BrandedProduct_ID],
            pak.Activation_Type,
            ap.PromoAmount
        INTO #POFilledA
        FROM #ActivationPromos ap
            JOIN dbo.tblOrderItemAddons oia
                ON ap.Promo_ID = oia.OrderID -- this join is to find the IDs to check for an activation   --Joining promo orders instead of activation orders
            JOIN dbo.tblAddonFamily af
                ON oia.AddonsID = af.AddonID
                AND af.AddonTypeName IN ( 'DeviceBYOPType', 'DeviceType' ) -- ESN only per Jacob ,'SimBYOPType','SimType'
            JOIN dbo.Phone_Active_Kit pak
                ON oia.AddonsValue = pak.Sim_ID
            JOIN dbo.Order_No b
                ON pak.PONumber = b.Order_no
                AND b.OrderType_ID IN ( 57, 58, 48, 49 ) --branded and marketplace orders
            JOIN dbo.Orders o
                ON b.Order_no = o.Order_no
                AND oia.AddonsValue = o.SKU;
        --  SELECT * FROM #POFilledA

        IF OBJECT_ID('tempdb..#ActivationAtributes') IS NOT NULL
        BEGIN
            DROP TABLE #ActivationAtributes;
        END;

        SELECT DISTINCT
            ap.Order_no,
            ap.RTR_TXN_REFERENCE1,
            ap.TXN_PIN,
            po.Activation_Type AS [ATTRIBUTE_4],
            po.PromoAmount [ATTRIBUTE_5]
        INTO #ActivationAtributes
        FROM #ActivationPromos ap
            JOIN #POFilledA po
                ON ap.ID = po.ID;

        -- SELECT * FROM #ActivationAtributes



        IF OBJECT_ID('tempdb..#activationfee') IS NOT NULL
        BEGIN
            DROP TABLE #activationfee;
        END;

        SELECT o.Order_no,
            o.Choice,
            o.TWSKU,
            ISNULL(o2.Price,0) - ISNULL(o2.DiscAmount,0) Price
        INTO #activationfee
        FROM #orders o
            LEFT JOIN order_no o1
                ON o.Order_no = o1.Order_no
            LEFT JOIN orders o2
                ON o2.Order_no = o1.Order_no
            LEFT JOIN Products p
                ON p.Product_ID = o2.Product_ID
            JOIN Products.tblProductType pt
                ON pt.ProductTypeID = p.Product_Type
                AND pt.producttypeid = 17
        WHERE o.Choice = 2;




        IF OBJECT_ID('tempdb..#finallookup') IS NOT NULL
        BEGIN
            DROP TABLE #finallookup;
        END;

        --Remove account details for Rural and Cstore
        SELECT DISTINCT
            bp.HOST_TIMESTAMP,
            bp.TXN_GROUP,
            bp.Sim,
            bp.Min,
            bp.RTR_TXN_REFERENCE1,
            bp.TXN_PIN,
            bp.TXN_SNP,
            bp.PRODUCT_NAME,
            bp.PRODUCT_SKU,
            bp.Product_Supplier,
            bp.VALUE,
            bp.TXN_TYPE,
            CASE
                WHEN ISNULL(tt.Tag, '') = 'TFRURAL' THEN
                    138379
                WHEN ISNULL(tt.Tag, '') = 'CStore' THEN
                    138380
                ELSE
                    bp.TSP_ID
            END TSP_ID,
            CASE
                WHEN ISNULL(tt.Tag, '') = 'TFRURAL' THEN
                    'TFRural'
                WHEN ISNULL(tt.Tag, '') = 'CStore' THEN
                    'CStore'
                ELSE
                    bp.DEALER_NAME
            END DEALER_NAME,
            CASE
                WHEN ISNULL(tt.Tag, '') IN ( 'TFRURAL', 'CStore' ) THEN
                    '7240 Muirfield Dr.'
                ELSE
                    bp.Address1
            END Address1,
            CASE
                WHEN ISNULL(tt.Tag, '') IN ( 'TFRURAL', 'CStore' ) THEN
                    ''
                ELSE
                    bp.Address2
            END Address2,
            CASE
                WHEN ISNULL(tt.Tag, '') IN ( 'TFRURAL', 'CStore' ) THEN
                    'Dublin'
                ELSE
                    bp.City
            END City,
            CASE
                WHEN ISNULL(tt.Tag, '') IN ( 'TFRURAL', 'CStore' ) THEN
                    'OH'
                ELSE
                    bp.State
            END State,
            CASE
                WHEN ISNULL(tt.Tag, '') IN ( 'TFRURAL', 'CStore' ) THEN
                    '43017' --KMH Added '' to prevent conversion error 2020-02-24
                ELSE
                    bp.Zip
            END Zip,
            CASE
                WHEN ISNULL(tt.Tag, '') IN ( 'TFRURAL', 'CStore' ) THEN
                    ''
                ELSE
                    REPLACE(
                                REPLACE(REPLACE(REPLACE(REPLACE(bp.PHONE_NUMBER, '-', ''), '.', ''), ' ', ''), '(', ''),
                                ')',
                                ''
                            )
            END PHONE_NUMBER,
            ISNULL(af.Price, '0') AS ATTRIBUTE_1,
            bp.ATTRIBUTE_2,
            bp.Attribute_3,
            CASE
                WHEN bp.TXN_GROUP IN ( 'RML', 'PIN', 'RTR' ) THEN
                    ISNULL(CAST(aa.ATTRIBUTE_4 AS VARCHAR(100)), '')
                WHEN bp.TXN_GROUP = 'SIM' THEN
                    'BYOP MIGRATION'
            END ATTRIBUTE_4, --AB 19.0 2019-01-16
            CASE
                WHEN bp.TXN_GROUP IN ( 'RML', 'PIN', 'RTR' ) THEN
                    ISNULL(CAST(aa.ATTRIBUTE_5 AS VARCHAR(100)), '0')
                WHEN bp.TXN_GROUP = 'SIM' THEN
                    ISNULL(CAST(bp.ATTRIBUTE_5 AS VARCHAR(100)), '0')
            END ATTRIBUTE_5, --AB 19.0 2019-01-16
            bp.Order_no
        INTO #finallookup
        FROM #finallookupBeforePromos bp
            LEFT JOIN #ActivationAtributes aa
                ON aa.Order_no = bp.Order_no
            LEFT JOIN Account.tblTags tt
                ON tt.SubjectId = bp.TSP_ID
            LEFT JOIN Tracfone.tblTracTSPAccountRegistration tar
                ON tar.Account_ID = bp.TSP_ID
            LEFT JOIN #activationfee af
                ON af.Order_no = bp.Order_no
        WHERE bp.TSP_ID != '149799'; --SB20220110 --Automation Refills Account to keep the orders housing house transactions from getting sent as duplicate


        IF @RunInsert = 1
        BEGIN
            --INSERT INTO CellDayTemp.Tracfone.tblTSPTransactionFeed
            SELECT DISTINCT
                HOST_TIMESTAMP,
                ISNULL(CAST(TXN_GROUP AS VARCHAR(10)), ' ') TXN_GROUP,
                ISNULL(CAST(Sim AS VARCHAR(25)), ' ') SIM,
                ISNULL(CAST([Min] AS VARCHAR(20)), ' ') MIN,
                ISNULL(CAST(RTR_TXN_REFERENCE1 AS VARCHAR(50)), ' ') RTR_TXN_REFERENCE1,
                ISNULL(CAST(TXN_PIN AS VARCHAR(50)), ' ') TXN_PIN,
                ISNULL(CAST(TXN_SNP AS VARCHAR(50)), ' ') TXN_SNP,
                ISNULL(CAST(PRODUCT_NAME AS VARCHAR(50)), ' ') PRODUCT_NAME,
                CAST(PRODUCT_SKU AS INT) PRODUCT_SKU,
                ISNULL(CAST(Product_Supplier AS VARCHAR(50)), ' ') PRODUCT_SUPPLIER,
                CAST(CAST(VALUE AS FLOAT) AS DECIMAL(6, 2)) VALUE,
                ISNULL(CAST(TXN_TYPE AS VARCHAR(10)), ' ') TXN_TYPE,
                ISNULL(CAST(TSP_ID AS VARCHAR(12)), ' ') TSP_ID,
                ISNULL(CAST(DEALER_NAME AS VARCHAR(50)), ' ') DEALER_NAME,
                ISNULL(CAST(Address1 AS VARCHAR(50)), ' ') ADDRESS1,
                ISNULL(CAST(Address2 AS VARCHAR(50)), ' ') ADDRESS2,
                ISNULL(CAST(City AS VARCHAR(50)), ' ') CITY,
                ISNULL(CAST(State AS VARCHAR(15)), ' ') STATE,
                ISNULL(CAST(Zip AS VARCHAR(12)), ' ') ZIP,
                ISNULL(CAST(PHONE_NUMBER AS VARCHAR(15)), ' ') PHONE_NUMBER,
                ISNULL(CAST(ATTRIBUTE_1 AS VARCHAR(100)), ' ') ATTRIBUTE_1,
                ISNULL(CAST(ATTRIBUTE_2 AS VARCHAR(100)), ' ') ATTRIBUTE_2,
                ISNULL(CAST(Attribute_3 AS VARCHAR(100)), ' ') ATTRIBUTE_3,
                ISNULL(CAST(ATTRIBUTE_4 AS VARCHAR(100)), ' ') ATTRIBUTE_4,
                ISNULL(CAST(ATTRIBUTE_5 AS VARCHAR(100)), ' ') ATTRIBUTE_5,
                CAST(Order_no AS INT) Order_no,
                GETDATE() Date_Created
            INTO CellDayTemp.dbo.finalruninsertt
            FROM #finallookup F
            WHERE (
                    ISNUMERIC(TXN_PIN) = 1
                    AND TXN_GROUP = 'Pin'
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP = 'rtr'
                    AND ISNUMERIC(RTR_TXN_REFERENCE1) = 1
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP = 'RML'
                    AND ISNULL(CAST(PRODUCT_SKU AS INT), ' ') = 8387
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP = 'RML'
                    AND ISNUMERIC(RTR_TXN_REFERENCE1) = 1
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    ISNULL(CAST(TXN_GROUP AS VARCHAR(10)), ' ') = 'SIM'
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                );

        END;




        IF @RunInsert = 2
        BEGIN

            IF
            (
                SELECT COUNT(DISTINCT Order_no)FROM #finallookup
            ) > 1
            BEGIN
                SELECT 'There is more than one record attempting insert.' Error;
                RETURN;
            END;

            INSERT INTO Tracfone.tblTSPTransactionFeed
            SELECT DISTINCT
                HOST_TIMESTAMP,
                ISNULL(CAST(TXN_GROUP AS VARCHAR(10)), ' ') TXN_GROUP,
                ISNULL(CAST(Sim AS VARCHAR(25)), ' ') SIM,
                ISNULL(CAST([Min] AS VARCHAR(20)), ' ') MIN,
                ISNULL(CAST(RTR_TXN_REFERENCE1 AS VARCHAR(50)), ' ') RTR_TXN_REFERENCE1,
                ISNULL(CAST(TXN_PIN AS VARCHAR(50)), ' ') TXN_PIN,
                ISNULL(CAST(TXN_SNP AS VARCHAR(50)), ' ') TXN_SNP,
                ISNULL(CAST(PRODUCT_NAME AS VARCHAR(50)), ' ') PRODUCT_NAME,
                CAST(PRODUCT_SKU AS INT) PRODUCT_SKU,
                ISNULL(CAST(Product_Supplier AS VARCHAR(50)), ' ') PRODUCT_SUPPLIER,
                CAST(CAST(VALUE AS FLOAT) AS DECIMAL(6, 2)) VALUE,
                ISNULL(CAST(TXN_TYPE AS VARCHAR(10)), ' ') TXN_TYPE,
                ISNULL(CAST(TSP_ID AS VARCHAR(12)), ' ') TSP_ID,
                ISNULL(CAST(DEALER_NAME AS VARCHAR(50)), ' ') DEALER_NAME,
                ISNULL(CAST(Address1 AS VARCHAR(50)), ' ') ADDRESS1,
                ISNULL(CAST(Address2 AS VARCHAR(50)), ' ') ADDRESS2,
                ISNULL(CAST(City AS VARCHAR(50)), ' ') CITY,
                ISNULL(CAST(State AS VARCHAR(15)), ' ') STATE,
                ISNULL(CAST(Zip AS VARCHAR(12)), ' ') ZIP,
                ISNULL(CAST(PHONE_NUMBER AS VARCHAR(15)), ' ') PHONE_NUMBER,
                ISNULL(CAST(ATTRIBUTE_1 AS VARCHAR(100)), ' ') ATTRIBUTE_1,
                ISNULL(CAST(ATTRIBUTE_2 AS VARCHAR(100)), ' ') ATTRIBUTE_2,
                ISNULL(CAST(Attribute_3 AS VARCHAR(100)), ' ') ATTRIBUTE_3,
                ISNULL(CAST(ATTRIBUTE_4 AS VARCHAR(100)), ' ') ATTRIBUTE_4,
                ISNULL(CAST(ATTRIBUTE_5 AS VARCHAR(100)), ' ') ATTRIBUTE_5,
                CAST(Order_no AS INT) Order_no,
                GETDATE() Date_Created,
                '0' Processed,
                '0' NebarProcessed,
                '0' AdditionalMonthsProcessed
            FROM #finallookup F
            WHERE (
                    ISNUMERIC(TXN_PIN) = 1
                    AND TXN_GROUP = 'Pin'
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP = 'rtr'
                    AND ISNUMERIC(RTR_TXN_REFERENCE1) = 1
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP = 'RML'
                    AND ISNULL(CAST(PRODUCT_SKU AS INT), ' ') = 8387
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP = 'RML'
                    AND ISNUMERIC(RTR_TXN_REFERENCE1) = 1
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    ISNULL(CAST(TXN_GROUP AS VARCHAR(10)), ' ') = 'SIM'
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                );

        END;


        IF @RunInsert = 0
        BEGIN
            SELECT DISTINCT
                HOST_TIMESTAMP,
                ISNULL(CAST(TXN_GROUP AS VARCHAR(10)), ' ') TXN_GROUP,
                ISNULL(CAST(Sim AS VARCHAR(25)), ' ') SIM,
                ISNULL(CAST(Min AS VARCHAR(20)), ' ') MIN,
                ISNULL(CAST(RTR_TXN_REFERENCE1 AS VARCHAR(50)), ' ') RTR_TXN_REFERENCE1,
                ISNULL(CAST(TXN_PIN AS VARCHAR(50)), ' ') TXN_PIN,
                ISNULL(CAST(TXN_SNP AS VARCHAR(50)), ' ') TXN_SNP,
                ISNULL(CAST(PRODUCT_NAME AS VARCHAR(50)), ' ') PRODUCT_NAME,
                ISNULL(CAST(PRODUCT_SKU AS INT), ' ') PRODUCT_SKU,
                ISNULL(CAST(Product_Supplier AS VARCHAR(50)), ' ') PRODUCT_SUPPLIER,
                ISNULL(CAST(CAST(VALUE AS FLOAT) AS DECIMAL(6, 2)), 0) VALUE,
                ISNULL(CAST(TXN_TYPE AS VARCHAR(10)), ' ') TXN_TYPE,
                ISNULL(CAST(TSP_ID AS VARCHAR(12)), ' ') TSP_ID,
                ISNULL(CAST(DEALER_NAME AS VARCHAR(50)), ' ') DEALER_NAME,
                ISNULL(CAST(Address1 AS VARCHAR(50)), ' ') ADDRESS1,
                ISNULL(CAST(Address2 AS VARCHAR(50)), ' ') ADDRESS2,
                ISNULL(CAST(City AS VARCHAR(50)), ' ') CITY,
                ISNULL(CAST(State AS VARCHAR(15)), ' ') STATE,
                ISNULL(CAST(Zip AS VARCHAR(12)), ' ') ZIP,
                ISNULL(CAST(PHONE_NUMBER AS VARCHAR(15)), ' ') PHONE_NUMBER,
                ISNULL(CAST(ATTRIBUTE_1 AS VARCHAR(100)), ' ') ATTRIBUTE_1,
                ISNULL(CAST(ATTRIBUTE_2 AS VARCHAR(100)), ' ') ATTRIBUTE_2,
                ISNULL(CAST(Attribute_3 AS VARCHAR(100)), ' ') ATTRIBUTE_3,
                ISNULL(CAST(ATTRIBUTE_4 AS VARCHAR(100)), ' ') ATTRIBUTE_4,
                ISNULL(CAST(ATTRIBUTE_5 AS VARCHAR(100)), ' ') ATTRIBUTE_5
            FROM #finallookup F
            WHERE (
                    ISNUMERIC(TXN_PIN) = 1
                    AND TXN_GROUP IN ( 'VZWPin', 'Pin' )
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                )
                OR
                (
                    TXN_GROUP IN ( 'VZWRTR', 'RTR' )
                    AND ISNUMERIC(RTR_TXN_REFERENCE1) = 1
                    AND TSP_ID NOT IN
                        (
                            SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                        )
                    OR
                    (
                        TXN_GROUP = 'RML'
                        AND ISNULL(CAST(PRODUCT_SKU AS INT), ' ') = 8387
                        AND TSP_ID NOT IN
                            (
                                SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                            )
                    )
                    OR
                    (
                        TXN_GROUP = 'RML'
                        AND ISNUMERIC(RTR_TXN_REFERENCE1) = 1
                        AND TSP_ID NOT IN
                            (
                                SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                            )
                    )
                    OR
                    (
                        ISNULL(CAST(TXN_GROUP AS VARCHAR(10)), ' ') IN ( 'VZWSIM', 'SIM' )
                        AND TSP_ID NOT IN
                            (
                                SELECT CAST(Account_ID AS VARCHAR(15))FROM Tracfone.tblAccountIssue
                            )
                    )
                )
            ORDER BY HOST_TIMESTAMP;
        END

    END TRY
    BEGIN CATCH

        SELECT ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END catch
END
-- noqa: disable=all;
/
