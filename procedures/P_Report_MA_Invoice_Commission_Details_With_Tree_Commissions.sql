--liquibase formatted sql

--changeset melissarios:213109 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/*=============================================
--      Author : Jacob Lowe -- noqa: LT01
--             :  -- noqa: LT01
-- Create Date : 2016-03-24
--             :  -- noqa: LT01
-- Description : Pulls orders that make up MA invoice
--  JL20180424 : Fixed hierarchy enforcement and optimize
--  AS20200318 : Added in logic for ProductCategory
--  MR20200518 : Removed the row number logic from MyCte and limit of 1 in the results. Added Where <> 0.00
--  MR20200519 : Added productTypeName  -- noqa: LT01
--  ZA20208024 : Added ACHinvoice check to filter out any other invoices under the same orderitem
--  MR20201002 : Added new Product Type naming to match the new invoice
--  MR20201009 : Updated Sleeve products to be "Marketplace: Marketing Materials"
--             : Updated the Elavon commission to have the product category of "Merchant Service Commission"
--  NG20210426 : Added ProductSubCategory column and cleaned ProductCategory column up also added a Left JOIN for ParentID on the category table to get Carrier Name -- noqa: LT05
--  MR20220309 : Casted [MaCommissionAmount] as Decimal(7,2)
--  MR20220322 : Casted [MaCommissionAmount] as Varchar(20) (Trying to get the decimals to appear in the CRM).
--  MR20220325 : Removed the "DISTINCT" from the #ListOfCommissions table since it was removing payments that were actually made twice to an account.  -- noqa: LT05
-- KMH20230831 : Added columns DateFilled, DirectParentCommissionDateDue, SIM, ESN,PONumber, [Product SKU], Company, UserID, username -- noqa: LT05
--  NG20230925 : Added @Option to be able to view > 0.00 Commissions and ALL Commissions
--  NG20231010 : Added Residuals to WHERE clause to 2nd option on report to remove them from results pane
--  MR20231108 : Re-arranged so that all the logic to further split apart option 0 and 1 so that Option 0 can run with "AND oc.Commission_Amt <> 0.00"  -- noqa: LT05
					in the #ListOfOrders section to improve performance and so that option 1 can run without SIMS and ESNs pulled in due to the larger run time with including zero commissions. -- noqa: LT05
			   : Added filled, void, processed flags in #ListOfOrders
			   : In the #PAK section, added #DistinctOrders0 table to eliminate duplicates, added a status check, limited to order types 22 and 23,  -- noqa: LT05
					deleted any SIMs less than length of 12, and took the MIN of the SIMs to eliminate duplicates.
			   : In the #orderAuth section, added a #PreOrderAuth table to bring in the SKU and joined on this SKU in the #orderAuth section to eliminate duplicates.  -- noqa: LT05
					Added filled, void, and processed flag checks here.
			   : Added DISTINCT to the #OIAAuth and #OIA sections and removed the OrderItemAddons and the AddonsID.
			   : Added the #MAXtspTransactionFeed section to just take the MAX to eliminate duplicates.
			   : Added error message to not be able to view the whole tree if pulling in zero dollar commissions.
			   : Removed "DISTINCT" from the final results due to not bringing back all the rows.
--  MR20231128 : Added an exception that session ID 2 can view zeros for children. (AND @sessionID <> 2)
--  MR20231129 : Took out the "DISTINCT" in the #ListOfCommInfo sections and add the SUM of commission_Amt
			   : Removed Commission_Amt DECIMAL(9,2), OrderType_ID INT from #ListOfOrders1
--  MR20240215 :  Removed join to product carrier mapping table in both options' final select statements. Add Fee column and Retail Cost column.
-----testing
			--  DECLARE  -- noqa: LT01
			--  @sessionID INT = 64363
			--, @Option INT = 1
			--, @InvoiceNumber INT = 226769400
			--, @SessionVsAll BIT = 0 -- 0 = Only Session , 1 = All Children
Broke the logic fully into @Option 0 and @Option 1 so that all of the logic AND oc.Commission_Amt <> 0.00;
--Usage : EXEC [Report].[P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions] 2, 42779039
-- =============================================*/
-- noqa: enable=all
ALTER   PROCEDURE [Report].[P_Report_MA_Invoice_Commission_Details_With_Tree_Commissions]
    (
        @sessionID INT
        , @Option INT
        , @InvoiceNumber INT
        , @SessionVsAll BIT-- 0 = Only Session , 1 = All Children
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        DECLARE @ACHNumber INT, @AccountID INT;

        IF
            NOT EXISTS
            (
                SELECT Account_ID
                FROM cellday_prod.dbo.Account
                WHERE Account_ID = @sessionID AND AccountType_ID IN (5, 6, 8)
            )
            BEGIN
                SELECT
                    'This report is restricted! If you need access, please see your T-Cetra Rep.' AS [Error Message];
                RETURN;
            END;

        IF @Option = 1 AND @SessionVsAll = 1 AND @sessionID <> 2 --MR20231128
            BEGIN
                SELECT
                    'If you are choosing to include zero dollar commissions, please select "Only Logged in Account".'
                        AS [Error Message]
                RETURN;
            END;

        IF OBJECT_ID('tempdb..#ListOfAccounts') IS NOT NULL
            BEGIN
                DROP TABLE #ListOfAccounts;
            END;

        CREATE TABLE #ListOfAccounts
        (AccountID INT);

        INSERT INTO #ListOfAccounts
        EXEC [Account].[P_Account_GetAccountList]
            @AccountID = @sessionID,              -- int
            @UserID = 1,                          -- int
            @AccountTypeID = '5,6,8',             -- varchar(50)
            @AccountStatusID = '0,1,2,3,4,5,6,7', -- varchar(50)
            @Simplified = 1;                      -- bit


        INSERT INTO #ListOfAccounts
        (AccountID)
        VALUES (@sessionID);

        -- SELECT * FROM #ListOfAccounts ORDER BY AccountID

        IF ISNULL(@InvoiceNumber, 0) <> 0
            BEGIN
                SELECT
                    @ACHNumber = n.InvoiceNum
                    , @AccountID = n.Account_ID
                FROM dbo.Order_No AS n
                JOIN #ListOfAccounts AS la
                    ON la.AccountID = n.Account_ID
                WHERE
                    n.Order_No = @InvoiceNumber
                    AND n.OrderType_ID IN (5, 6)
            END;


        IF (ISNULL(@ACHNumber, 0) = 0)
            BEGIN
                SELECT 'Invalid Invoice Number.' AS [Error Message];
                RETURN;
            END;

        IF @Option = 0 --NG20230925 (Do not show zero dollar commissions)
            BEGIN

                IF OBJECT_ID('tempdb..#ListOfOrders0') IS NOT NULL
                    BEGIN
                        DROP TABLE #ListOfOrders0;
                    END;

                CREATE TABLE #ListOfOrders0
                (
                    Orders_ID INT, Order_No INT, AuthNumber INT, OrderType_ID INT
                )

                INSERT INTO #ListOfOrders0
                (
                    Orders_ID, Order_No, AuthNumber, OrderType_ID
                )
                SELECT DISTINCT
                    oc.Orders_ID
                    , oc.Order_No
                    , CONVERT(INT, od.AuthNumber) AS AuthNumber
                    , od.OrderType_ID
                FROM dbo.Order_Commission AS oc
                JOIN dbo.order_no AS od
                    ON
                        od.Order_No = oc.Order_No
                        AND od.Filled = 1				--MR20231108
                        AND od.Void = 0
                        AND od.Process = 1
                WHERE
                    oc.Account_ID = @AccountID
                    AND oc.InvoiceNum = @ACHNumber
                    AND oc.Commission_Amt <> 0.00;	 --MR20231108


                CREATE INDEX idx_OrderID ON #ListOfOrders0 (Orders_ID)		-- LUX
                CREATE INDEX idx_AuthNumber ON #ListOfOrders0 (AuthNumber)	-- LUX


                DROP TABLE IF EXISTS #DistinctOrders0

                SELECT DISTINCT lo.Order_No, lo.OrderType_ID	--MR20231108
                INTO #DistinctOrders0
                FROM #ListOfOrders0 AS lo


                DROP TABLE IF EXISTS #PrePAK	--MR20231108

                SELECT
                    pak.order_no
                    , pak.Sim_ID
                    , pak.PONumber
                    , LEN(pak.Sim_ID) AS LEN_SIM_ID
                INTO #PrePAK
                FROM #DistinctOrders0 AS lo
                JOIN dbo.Phone_Active_Kit AS pak
                    ON
                        lo.Order_No = pak.order_no
                        AND pak.Status = 1
                WHERE lo.OrderType_ID IN (22, 23)

                DELETE pak FROM #PrePAK AS pak
                WHERE LEN(pak.Sim_ID) < 12

                DROP TABLE IF EXISTS #PAK	-- LUX

                SELECT
                    p.order_no,			-- LUX
                    MIN(p.Sim_ID) AS Sim_ID,
                    MIN(p.LEN_SIM_ID) AS LEN_SIM_ID,
                    MIN(ISNULL(p.PONumber, '')) AS PONumber
                INTO #PAK
                FROM #PrePAK AS p
                WHERE p.LEN_SIM_ID < 16
                GROUP BY p.order_no
                UNION
                SELECT
                    p.order_no,
                    MIN(p.Sim_ID) AS Sim_ID,
                    MIN(p.LEN_SIM_ID) AS LEN_SIM_ID,
                    MIN(ISNULL(p.PONumber, '')) AS PONumber
                FROM #PrePAK AS p
                WHERE p.LEN_SIM_ID > 16
                GROUP BY p.order_no

                ---------------------------------------------------------------------------------
                --  Find order based on AuthNumber
                ---------------------------------------------------------------------------------
                DROP TABLE IF EXISTS #PreOrderAuth;

                SELECT
                    o.Orders_ID,
                    o.Order_No,
                    o.AuthNumber,
                    o.OrderType_ID,
                    d.SKU
                INTO #PreOrderAuth
                FROM #ListOfOrders0 AS o
                JOIN dbo.orders AS d
                    ON d.ID = o.Orders_ID
                WHERE ISNULL(o.AuthNumber, '') <> ''

                DROP TABLE IF EXISTS #OrderAuth;

                SELECT
                    d2.ID AS AuthOrderID
                    , d2.Order_No
                    , ord.Orders_ID AS OrgOrderId
                INTO #OrderAuth
                FROM dbo.Orders AS d2
                JOIN #PreOrderAuth AS ord
                    ON
                        d2.Order_No = ord.AuthNumber
                        AND d2.SKU = ord.SKU
                        AND ISNULL(d2.ParentItemID, 0) IN (0, 1)
                        AND ISNULL(ord.AuthNumber, '') <> '' --MR20231108
                JOIN dbo.order_no AS n
                    ON
                        n.Order_No = ord.Order_No
                        AND n.Filled = 1		--MR20231108
                        AND n.Void = 0
                        AND n.Process = 1

                --   ------------------------------------------------------------------------
                --   -- Get data tblOrderItemAddons based on orders
                --   ------------------------------------------------------------------------


                DROP TABLE IF EXISTS #OiA;

                SELECT DISTINCT	--MR20231108 (Added distinct)
                    A.OrderID
                    , A.AddonsValue
                    , f2.AddonTypeName
                INTO #OiA
                FROM #ListOfOrders0 AS B
                JOIN dbo.tblOrderItemAddons AS A
                    ON B.Orders_ID = A.OrderID
                JOIN dbo.tblAddonFamily AS f2
                    ON
                        f2.AddonID = A.AddonsID
                        AND f2.AddonTypeName IN ('SimType', 'SimBYOPType', 'DeviceType', 'DeviceBYOPType')

                --   --------------------------------------------------------------------------
                --   -- Get data tblOrderItemAddons based on AuthNumber
                --   --------------------------------------------------------------------------
                DROP TABLE IF EXISTS #OIAAuth;

                SELECT DISTINCT --MR20231108 (Added distinct)
                    A.OrderID
                    , A.AddonsValue
                    , B.Order_No
                    , f2.AddonTypeName
                INTO #OIAAuth
                FROM #OrderAuth AS B
                JOIN dbo.tblOrderItemAddons AS A
                    ON B.AuthOrderID = A.OrderID
                JOIN dbo.tblAddonFamily AS f2
                    ON
                        f2.AddonID = A.AddonsID
                        AND f2.AddonTypeName IN ('SimType', 'SimBYOPType', 'DeviceType', 'DeviceBYOPType');


                IF OBJECT_ID('tempdb..#ListOfCommInfo0') IS NOT NULL
                    BEGIN
                        DROP TABLE #ListOfCommInfo0;
                    END;


                ; WITH cteListOfCommissions AS (
                    SELECT					--MR20220325
                        oc.Orders_ID
                        , oc.Account_ID
                        , oc.Commission_Amt
                        , oc.InvoiceNum
                        , oc.Datedue
                    FROM dbo.Order_Commission AS oc
                    JOIN #ListOfAccounts AS la
                        ON
                            la.AccountID = oc.Account_ID
                            AND (
                                (@SessionVsAll = 1)
                                OR
                                (@SessionVsAll = 0 AND la.AccountID = @sessionID)
                            )
                    WHERE
                        oc.Account_ID <> 2
                        AND oc.Commission_Amt <> 0
                        AND EXISTS (SELECT 1 FROM #ListOfOrders0 AS lo WHERE lo.Orders_ID = oc.Orders_ID)
                )
                SELECT
                    lc.Orders_ID
                    , lc.Account_ID
                    , lc.InvoiceNum		--MR20231129
                    , lc.Datedue
                    , SUM(lc.Commission_Amt) AS Commission_Amt
                    , CONVERT(VARCHAR(MAX), n.Order_No) AS [MaInvoiceNumber]
                    , CONVERT(DATETIME, n.DateDue) AS [MADateDue]

                INTO
                #ListOfCommInfo0
                FROM
                    cteListOfCommissions AS lc
                LEFT JOIN dbo.Order_No AS n
                    ON
                        lc.InvoiceNum = n.InvoiceNum
                        AND lc.InvoiceNum IS NOT NULL
                        AND n.Account_ID = lc.Account_ID
                        AND n.OrderType_ID IN (5, 6)
                GROUP BY
                    CONVERT(VARCHAR(MAX), n.Order_No),
                    n.DateDue,
                    lc.Orders_ID,
                    lc.Account_ID,
                    lc.InvoiceNum,
                    lc.Datedue


                IF OBJECT_ID('tempdb..#ProductCategory0') IS NOT NULL
                    BEGIN
                        DROP TABLE #ProductCategory0;
                    END;

                SELECT
                    lo.Orders_ID
                    , o.Name
                    , o.Product_ID
                    , o.Price
                    , o.DiscAmount
					, ISNULL(o.Fee, 0.00) AS Fee --MR20240215
                    , o.Product_ID AS [Product SKU]
                    , CASE
                        WHEN pt.ProductTypeName = 'PinRtr' THEN 'Airtime'
                        WHEN ISNULL(pt.ProductTypeName, 'PIN') = 'PIN' THEN 'Airtime'
                        WHEN pt.ProductTypeName = 'RTR' THEN 'Airtime'
                        WHEN pt.ProductTypeName = 'Sim' THEN 'SIM'
                        WHEN pt.ProductTypeName = 'CredCardValidation' THEN 'Credit Card Validation'
                        WHEN pt.ProductTypeName = 'CredCardDeposit' THEN 'Credit Card Deposit'
                        WHEN pt.ProductTypeName = 'FeeProduct' AND p.Product_ID = 8927 THEN 'Merchant Processing'
                        WHEN pt.ProductTypeName = 'FeeProduct' AND p.Product_ID <> 8927 THEN 'Fee'
                        WHEN pt.ProductTypeName = 'CashDeposit' THEN 'Cash Deposit'
                        WHEN pt.ProductTypeName = 'ActivationFee' THEN 'Activation Fee'
                        WHEN pt.ProductTypeName = 'SpiffSplit' THEN 'Spiff: Additional Month Spiff'
                        WHEN pt.ProductTypeName = 'BillPay' THEN 'Bill Pay'
                        WHEN pt.ProductTypeName = 'CreditCardVerification' THEN 'Credit Card Verification'
                        WHEN pt.ProductTypeName = 'ConsumerPromotion' THEN 'Consumer Promotion'
                        WHEN pt.ProductTypeName = 'TradeIn' THEN 'Trade-In'
                        WHEN pt.ProductTypeName = 'Marketplace'
                            THEN
                                CASE
                                    WHEN p.SubProductTypeId = 5 THEN 'Marketplace: SIM Cards'
                                    WHEN p.SubProductTypeId IN (2, 3, 4, 6, 7, 8) THEN 'Marketplace: Unlocked Handsets'
                                    WHEN
                                        p.SubProductTypeId = 10 AND pa.Value IN ('laptop', '2n1', 'tablet')
                                        THEN 'Marketplace: Tablets and Laptops'
                                    WHEN
                                        p.SubProductTypeId = 10
                                        AND ISNULL(pa.Value, '') NOT IN ('laptop', '2n1', 'tablet')
                                        THEN 'Marketplace: Accessories'
                                    WHEN p.SubProductTypeId = 13 THEN 'Marketplace: Marketing Materials'
                                    ELSE 'Marketplace: Other'
                                END
                        WHEN pt.ProductTypeName = 'Branded Handset' THEN 'Marketplace: Branded Handset'
                        ELSE pt.ProductTypeName
                    END AS [ProductTypeName]		--KMH20230831
                INTO #ProductCategory0
                FROM #ListOfOrders0 AS lo
                JOIN dbo.Orders AS o
                    ON o.ID = lo.Orders_ID
                JOIN dbo.products AS p
                    ON p.Product_ID = o.Product_ID
                LEFT JOIN products.tblProductType AS pt
                    ON pt.ProductTypeID = p.Product_Type
                LEFT JOIN MarketPlace.tblProductAttributes AS pa
                    ON
                        pa.Product_ID = p.Product_ID
                        AND pa.AttributeID = 13


                DROP TABLE IF EXISTS #MAXtspTransactionFeed

                SELECT
                    lo.Order_No,
                    MAX(f.TSPTransactionFeedID) AS FeedID
                INTO #MAXtspTransactionFeed
                FROM #DistinctOrders0 AS lo
                JOIN Tracfone.tblTSPTransactionFeed AS f
                    ON f.Order_No = lo.Order_No
                WHERE ISNULL(f.TXN_PIN, '') <> ''
                GROUP BY lo.Order_No

                DROP TABLE IF EXISTS #tspTransactionFeed

                SELECT
                    f.Order_No,
                    f.TXN_PIN
                INTO #tspTransactionFeed
                FROM tracfone.tblTSPTransactionFeed AS f
                JOIN #MAXtspTransactionFeed AS tf
                    ON f.TSPTransactionFeedID = tf.FeedID

                ; WITH MyCte AS (
                    SELECT
                        n.Order_No
                        , pc1.Name AS [Product]
                        , pc1.Product_ID
                        , pc1.ProductTypeName
                        , pc1.Price
                        , pc1.DiscAmount
						, pc1.Fee
                        , n.Account_ID
                        , n.DateOrdered
                        , n.DateFilled	--KMH20230831
                        , lci.Account_ID AS [MA]
                        , lci.Commission_Amt AS [MaCommissionAmount]
                        , lci.Datedue AS [DateDue]			--KMH20230831
                        , paksim.PONumber AS PONumber
                        , pc1.[Product SKU]
                        , cust.Company AS [Company]					--KMH20230831
                        --KMH20230831
                        , n.User_ID AS [UserID]
                        , u.UserName AS [username]			--KMH20230831
                        --, o.Product_ID AS [Product SKU]		--KMH20230831
                        , ISNULL(lci.MaInvoiceNumber, '') AS [MaInvoiceNumber]
                        , ISNULL(lci.MADateDue, '') AS [MADateDue]		--KMH20230831
                        , ISNULL(pakSIM.Sim_ID, ISNULL(OIAAuthSIM.AddonsValue, '')) AS [SIM]				--KMH20230831
                        --KMH20230831
                        , COALESCE(pakESN.Sim_ID, OIAAuthESN.AddonsValue, OIAOESN.AddonsValue, tf.TXN_PIN, '') AS ESN
                    FROM #ListOfOrders0 AS lo
                    JOIN dbo.Order_No AS n
                        ON n.Order_No = lo.Order_No
                    JOIN #ProductCategory0 AS pc1
                        ON pc1.Orders_ID = lo.Orders_ID
                    JOIN dbo.Users AS u
                        ON u.User_ID = n.User_ID
                    LEFT JOIN #ListOfCommInfo0 AS lci
                        ON lci.Orders_ID = lo.Orders_ID
                    JOIN dbo.Customers AS cust
                        ON n.Customer_ID = cust.Customer_ID
                    LEFT JOIN #PAK AS pakSIM	-- LUX
                        ON
                            pakSIM.order_no = n.Order_No
                            AND pakSIM.Len_SIM_ID > 16
                    LEFT JOIN #PAK AS pakESN	-- LUX
                        ON
                            pakESN.order_no = n.Order_No
                            AND pakESN.LEN_Sim_ID < 16
                    LEFT JOIN #OrderAuth AS d2
                        ON d2.OrgOrderId = lo.Orders_ID
                    LEFT JOIN #OIAAuth AS OIAAuthSIM
                        ON
                            OIAAuthSIM.OrderID = d2.AuthOrderID
                            AND oiaauthsim.AddonTypeName IN ('SimType', 'SimBYOPType')
                    LEFT JOIN #OIAAuth AS OIAAuthESN
                        ON
                            OIAAuthESN.OrderID = d2.AuthOrderID
                            AND OIAAuthESN.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
                    LEFT JOIN #OiA AS OIAOESN
                        ON
                            OIAOESN.OrderID = lo.Orders_ID
                            AND OIAOESN.AddonTypeName IN ('DeviceType', 'DeviceBYOPType')
                    LEFT JOIN #tspTransactionFeed AS tf
                        ON tf.Order_No = lo.Order_No
                )
                --AS202020318 #INC-338347

                SELECT
                    m.Order_No
                    , m.Product
                    , m.ProductTypeName
                    , m.Price
                    , m.DiscAmount
					, m.Fee
					, (m.Price - m.DiscAmount + m.Fee) AS RetailCost --MR20240215
                    , m.Account_ID
                    , m.DateOrdered
                    , m.DateFilled
                    , m.[MA]
                    , m.DateDue AS DirectParentCommissionDateDue		--KMH20230831
                    , m.[MaInvoiceNumber]
                    , m.[MADateDue]
                    , m.SIM		--KMH20230831			--KMH20230831
                    , m.ESN
                    , m.PONumber
                    , m.[Product SKU]					--KMH20230831
                    , m.Company					--KMH20230831
                    , m.UserID			--KMH20230831
                    , m.username		--KMH20230831
                    , CASE
                        WHEN m.ProductTypeName = 'Activation' THEN C2.Name          --NG20210426
                        WHEN m.Product_ID = 10428 THEN 'Merchant Service Commission'
                        ELSE C.Name
                    END AS [ProductCategory]				--KMH20230831
                    , CASE
                        --NG20210426
                        WHEN
                            m.ProductTypeName = 'Activation'
                            THEN IIF(m.Product_ID = 10428, 'Merchant Service Commission', c.Name)
                        ELSE ''
                    END AS ProductSubCategory				--KMH20230831
                    , CONVERT(VARCHAR(20), m.[MaCommissionAmount]) AS [MaCommissionAmount]			--KMH20230831
                FROM MyCte AS m
                LEFT JOIN dbo.Product_Category AS PC WITH (READUNCOMMITTED)
                    ON m.Product_ID = PC.Product_ID
                LEFT JOIN dbo.Categories AS C WITH (READUNCOMMITTED)
                    ON PC.Category_ID = C.Category_ID
                LEFT JOIN dbo.Categories AS C2 WITH (READUNCOMMITTED)
                    ON C2.Category_ID = C.Parent_ID    --NG20210426
                ORDER BY
                    m.Order_No, m.MA;

            --AS202020318 #INC-338347

            END;

        IF @Option = 1 --NG20230925 (Show zero dollar commissions. Logged in account only).
            BEGIN
                IF OBJECT_ID('tempdb..#ListOfOrders1') IS NOT NULL
                    BEGIN
                        DROP TABLE #ListOfOrders1;
                    END;

                CREATE TABLE #ListOfOrders1
                (
                    Orders_ID INT, Order_No INT
                --Commission_Amt DECIMAL(9,2), OrderType_ID INT
                )

                INSERT INTO #ListOfOrders1
                (
                    Orders_ID, Order_No
                )
                SELECT DISTINCT
                    oc.Orders_ID
                    , oc.Order_No
                FROM dbo.Order_Commission AS oc
                JOIN dbo.order_no AS od
                    ON
                        od.Order_No = oc.Order_No
                        AND od.Filled = 1
                        AND od.Void = 0
                        AND od.Process = 1
                WHERE
                    oc.Account_ID = @AccountID
                    AND oc.InvoiceNum = @ACHNumber


                CREATE INDEX idx_OrderID ON #ListOfOrders1 (Orders_ID)		-- LUX

                IF OBJECT_ID('tempdb..#ListOfCommInfo1') IS NOT NULL
                    BEGIN
                        DROP TABLE #ListOfCommInfo1;
                    END;


                ; WITH cteListOfCommissions AS (
                    SELECT					--MR20220325
                        oc.Orders_ID
                        , oc.Account_ID
                        , oc.Commission_Amt
                        , oc.InvoiceNum
                        , oc.Datedue
                    FROM dbo.Order_Commission AS oc
                    JOIN #ListOfAccounts AS la
                        ON
                            la.AccountID = oc.Account_ID
                            AND (
                                (@SessionVsAll = 1)
                                OR
                                (@SessionVsAll = 0 AND la.AccountID = @sessionID)
                            )
                    WHERE
                        oc.Account_ID <> 2
                        AND EXISTS (SELECT 1 FROM #ListOfOrders1 AS lo WHERE lo.Orders_ID = oc.Orders_ID)
                )

                SELECT
                    lc.Orders_ID
                    , lc.Account_ID
                    , lc.InvoiceNum
                    , lc.Datedue
                    , SUM(lc.Commission_Amt) AS Commission_Amt
                    , CONVERT(VARCHAR(MAX), n.Order_No) AS [MaInvoiceNumber]
                    , CONVERT(DATETIME, n.DateDue) AS [MADateDue]
                INTO
                #ListOfCommInfo1
                FROM
                    cteListOfCommissions AS lc
                LEFT JOIN dbo.Order_No AS n
                    ON
                        lc.InvoiceNum = n.InvoiceNum
                        AND lc.InvoiceNum IS NOT NULL
                        AND n.Account_ID = lc.Account_ID
                        AND n.OrderType_ID IN (5, 6)
                GROUP BY
                    CONVERT(VARCHAR(MAX), n.Order_No),
                    n.DateDue,
                    lc.Orders_ID,
                    lc.Account_ID,
                    lc.InvoiceNum,
                    lc.Datedue


                IF OBJECT_ID('tempdb..#ProductCategory1') IS NOT NULL
                    BEGIN
                        DROP TABLE #ProductCategory1;
                    END;

                SELECT
                    lo.Orders_ID
                    , o.Name
                    , o.Product_ID
                    , o.Price
                    , o.DiscAmount
					, ISNULL(o.Fee, 0.00) AS Fee
                    , o.Product_ID AS [Product SKU]
                    , CASE
                        WHEN pt.ProductTypeName = 'PinRtr' THEN 'Airtime'
                        WHEN ISNULL(pt.ProductTypeName, 'PIN') = 'PIN' THEN 'Airtime'
                        WHEN pt.ProductTypeName = 'RTR' THEN 'Airtime'
                        WHEN pt.ProductTypeName = 'Sim' THEN 'SIM'
                        WHEN pt.ProductTypeName = 'CredCardValidation' THEN 'Credit Card Validation'
                        WHEN pt.ProductTypeName = 'CredCardDeposit' THEN 'Credit Card Deposit'
                        WHEN pt.ProductTypeName = 'FeeProduct' AND p.Product_ID = 8927 THEN 'Merchant Processing'
                        WHEN pt.ProductTypeName = 'FeeProduct' AND p.Product_ID <> 8927 THEN 'Fee'
                        WHEN pt.ProductTypeName = 'CashDeposit' THEN 'Cash Deposit'
                        WHEN pt.ProductTypeName = 'ActivationFee' THEN 'Activation Fee'
                        WHEN pt.ProductTypeName = 'SpiffSplit' THEN 'Spiff: Additional Month Spiff'
                        WHEN pt.ProductTypeName = 'BillPay' THEN 'Bill Pay'
                        WHEN pt.ProductTypeName = 'CreditCardVerification' THEN 'Credit Card Verification'
                        WHEN pt.ProductTypeName = 'ConsumerPromotion' THEN 'Consumer Promotion'
                        WHEN pt.ProductTypeName = 'TradeIn' THEN 'Trade-In'
                        WHEN pt.ProductTypeName = 'Marketplace'
                            THEN
                                CASE
                                    WHEN p.SubProductTypeId = 5 THEN 'Marketplace: SIM Cards'
                                    WHEN p.SubProductTypeId IN (2, 3, 4, 6, 7, 8) THEN 'Marketplace: Unlocked Handsets'
                                    WHEN
                                        p.SubProductTypeId = 10 AND pa.Value IN ('laptop', '2n1', 'tablet')
                                        THEN 'Marketplace: Tablets and Laptops'
                                    WHEN
                                        p.SubProductTypeId = 10
                                        AND ISNULL(pa.Value, '') NOT IN ('laptop', '2n1', 'tablet')
                                        THEN 'Marketplace: Accessories'
                                    WHEN p.SubProductTypeId = 13 THEN 'Marketplace: Marketing Materials'
                                    ELSE 'Marketplace: Other'
                                END
                        WHEN pt.ProductTypeName = 'Branded Handset' THEN 'Marketplace: Branded Handset'
                        ELSE pt.ProductTypeName
                    END AS [ProductTypeName]		--KMH20230831
                INTO #ProductCategory1
                FROM #ListOfOrders1 AS lo
                JOIN dbo.Orders AS o
                    ON o.ID = lo.Orders_ID
                JOIN dbo.products AS p
                    ON p.Product_ID = o.Product_ID
                LEFT JOIN products.tblProductType AS pt
                    ON pt.ProductTypeID = p.Product_Type
                LEFT JOIN MarketPlace.tblProductAttributes AS pa
                    ON
                        pa.Product_ID = p.Product_ID
                        AND pa.AttributeID = 13


                ; WITH MyCte AS (
                    SELECT
                        n.Order_No
                        , pc1.Name AS [Product]
                        , pc1.Product_ID
                        , pc1.ProductTypeName
                        , pc1.Price
                        , pc1.DiscAmount
						, pc1.Fee
                        , n.Account_ID
                        , n.DateOrdered
                        , n.DateFilled	--KMH20230831
                        , lci.Account_ID AS [MA]
                        , lci.Commission_Amt AS [MaCommissionAmount]
                        , lci.Datedue AS [DateDue]			--KMH20230831
                        , pc1.[Product SKU]
                        , cust.Company AS [Company]
                        , n.User_ID AS [UserID]
                        , u.UserName AS [username]		--KMH20230831
                        , ISNULL(lci.MaInvoiceNumber, '') AS [MaInvoiceNumber]				--KMH20230831
                        , ISNULL(lci.MADateDue, '') AS [MADateDue]			--KMH20230831
                    FROM #ListOfOrders1 AS lo
                    JOIN dbo.Order_No AS n
                        ON n.Order_No = lo.Order_No
                    JOIN #ProductCategory1 AS pc1
                        ON pc1.Orders_ID = lo.Orders_ID
                    JOIN dbo.Users AS u
                        ON u.User_ID = n.User_ID
                    LEFT JOIN #ListOfCommInfo1 AS lci
                        ON lci.Orders_ID = lo.Orders_ID
                    JOIN dbo.Customers AS cust
                        ON n.Customer_ID = cust.Customer_ID
                )
                --AS202020318 #INC-338347
                SELECT
                    m.Order_No
                    , m.Product
                    , m.ProductTypeName
                    , m.Price
                    , m.DiscAmount
					, m.Fee --MR20240215
					, (m.Price - m.DiscAmount + m.Fee) AS RetailCost --MR20240215
                    , m.Account_ID
                    , m.DateOrdered
                    , m.DateFilled
                    , m.[MA]
                    , m.DateDue AS DirectParentCommissionDateDue		--KMH20230831
                    , m.[MaInvoiceNumber]
                    , m.[MADateDue]
                    , m.[Product SKU] --KMH20230831
                    , m.Company
                    , m.UserID
                    , m.username		--KMH20230831
                    , CASE
                        WHEN m.ProductTypeName = 'Activation' THEN C2.Name          --NG20210426
                        WHEN m.Product_ID = 10428 THEN 'Merchant Service Commission'
                        ELSE C.Name
                    END AS [ProductCategory]				--KMH20230831
                    , CASE
                        --NG20210426
                        WHEN
                            m.ProductTypeName = 'Activation'
                            THEN IIF(m.Product_ID = 10428, 'Merchant Service Commission', c.Name)
                        ELSE ''
                    END AS ProductSubCategory				--KMH20230831
                    , CONVERT(VARCHAR(20), m.[MaCommissionAmount]) AS [MaCommissionAmount]			--KMH20230831
                FROM MyCte AS m
                LEFT JOIN dbo.Product_Category AS PC WITH (READUNCOMMITTED)
                    ON m.Product_ID = PC.Product_ID
                LEFT JOIN dbo.Categories AS C WITH (READUNCOMMITTED)
                    ON PC.Category_ID = C.Category_ID
                LEFT JOIN dbo.Categories AS C2 WITH (READUNCOMMITTED)
                    ON C2.Category_ID = C.Parent_ID    --NG20210426

            END;


        DROP TABLE IF EXISTS #ListOfAccounts;
        DROP TABLE IF EXISTS #ListOfOrders0;
        DROP TABLE IF EXISTS #DistinctOrders0;
        DROP TABLE IF EXISTS #PrePAK;
        DROP TABLE IF EXISTS #PAK;
        DROP TABLE IF EXISTS #PreOrderAuth;
        DROP TABLE IF EXISTS #OrderAuth;
        DROP TABLE IF EXISTS #OiA;
        DROP TABLE IF EXISTS #OIAAuth;
        DROP TABLE IF EXISTS #ListOfCommInfo0;
        DROP TABLE IF EXISTS #ProductCategory0;
        DROP TABLE IF EXISTS #MAXtspTransactionFeed
        DROP TABLE IF EXISTS #tspTransactionFeed
        DROP TABLE IF EXISTS #ListOfOrders1;
        DROP TABLE IF EXISTS #ListOfCommInfo1;
        DROP TABLE IF EXISTS #ProductCategory1;


    END TRY
    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber
            , ERROR_MESSAGE() AS ErrorMessage;
    END CATCH;

END
-- noqa: disable=all
/
